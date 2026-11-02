`timescale 1ns / 1ps
// ---------------------------------------------------------------------------
// ProcessingElement  (ASIC version)
//
// Changes vs. the KV260 version:
//  1. Xilinx mult_IP is gone. The multiply is plain signed Verilog followed by
//     ONE register, which is exactly the latency mult_IP was configured for
//     (LP_MULT_LATENCY = 1). PE latency stays 2 cycles, so every alignment
//     constant upstream/downstream is unchanged.
//  2. Weights arrive through a vertical shift chain
//        i_weight_shift_in -> r_weight_shift -> o_weight_shift_out
//     instead of a 32x32x8 = 8192-bit parallel bus from GemmComputeCore.
//     i_weight_load copies r_weight_shift into the active weight register,
//     the same moment the old design latched the parallel bus. Cycle
//     behaviour is identical; only the wiring became local.
//  3. P_DATAPATH_RESET = 0 drops the async reset on pure datapath flops
//     (feature, product, psum). Smaller cells and a lighter reset tree.
//     Keep it at 1 until the equivalence test passes, then try 0.
// ---------------------------------------------------------------------------
module ref_ProcessingElement
#(
    parameter P_DATA_WIDTH      = 8,
    parameter P_ROW_INDEX_WIDTH = 5,
    parameter P_DATAPATH_RESET  = 1
)
(
    input                                                   i_clk,
    input                                                   i_rst_n,
    input                                                   i_weight_shift_en,
    input                                                   i_weight_load,
    input      signed [P_DATA_WIDTH-1:0]                    i_weight_shift_in,
    output     signed [P_DATA_WIDTH-1:0]                    o_weight_shift_out,
    input      signed [P_DATA_WIDTH-1:0]                    i_feature_value,
    input      signed [2*P_DATA_WIDTH+P_ROW_INDEX_WIDTH-1:0] i_partial_sum,
    output reg signed [P_DATA_WIDTH-1:0]                    o_feature_value,
    output reg signed [2*P_DATA_WIDTH+P_ROW_INDEX_WIDTH-1:0] o_partial_sum
);
localparam integer LP_PSUM_WIDTH = 2*P_DATA_WIDTH + P_ROW_INDEX_WIDTH;
localparam integer LP_PROD_WIDTH = 2*P_DATA_WIDTH;

reg  signed [P_DATA_WIDTH-1:0]  r_weight_shift;   // shift-chain stage
reg  signed [P_DATA_WIDTH-1:0]  r_weight_value;   // active (stationary) weight
reg  signed [LP_PROD_WIDTH-1:0] r_product;        // = old mult_IP output reg
reg  signed [LP_PSUM_WIDTH-1:0] r_partial_sum_d1;

wire signed [LP_PROD_WIDTH-1:0] w_product     = i_feature_value * r_weight_value;
wire signed [LP_PSUM_WIDTH-1:0] w_product_ext = {{(LP_PSUM_WIDTH-LP_PROD_WIDTH){r_product[LP_PROD_WIDTH-1]}}, r_product};

assign o_weight_shift_out = r_weight_shift;

// Weight registers always keep their reset (small, and it keeps gate-level
// simulation free of X before the first tile is loaded).
always @(posedge i_clk or negedge i_rst_n) begin
    if (~i_rst_n) begin
        r_weight_shift <= 0;
        r_weight_value <= 0;
    end
    else begin
        if (i_weight_shift_en)
            r_weight_shift <= i_weight_shift_in;
        if (i_weight_load)
            r_weight_value <= r_weight_shift;
    end
end

generate
    if (P_DATAPATH_RESET) begin : g_dp_rst
        always @(posedge i_clk or negedge i_rst_n) begin
            if (~i_rst_n) begin
                r_product        <= 0;
                r_partial_sum_d1 <= 0;
                o_partial_sum    <= 0;
                o_feature_value  <= 0;
            end
            else begin
                r_product        <= w_product;
                r_partial_sum_d1 <= i_partial_sum;
                o_partial_sum    <= r_partial_sum_d1 + w_product_ext;
                o_feature_value  <= i_feature_value;
            end
        end
    end
    else begin : g_dp_norst
        always @(posedge i_clk) begin
            r_product        <= w_product;
            r_partial_sum_d1 <= i_partial_sum;
            o_partial_sum    <= r_partial_sum_d1 + w_product_ext;
            o_feature_value  <= i_feature_value;
        end
    end
endgenerate

endmodule
`timescale 1ns / 1ps
`include "gemm_asic_cfg.vh"
// ---------------------------------------------------------------------------
// ProcessingElementRow  (ASIC version)  -  this is the module hardened as a
// macro and instantiated GEMM_N times.
//
// Boundary (all short, all registered on at least one side):
//   top edge    : i_partial_sum_vector  (psum flows DOWN)
//                 o_weight_shift_out    (weights flow UP)
//   bottom edge : o_partial_sum_vector
//                 i_weight_shift_in
//   left edge   : i_feature_value, i_clk, i_rst_n, i_weight_shift_en,
//                 i_weight_load
// Pin j of the top edge sits exactly above pin j of the bottom edge
// (pin_order.cfg from openlane/gen_openlane_files.py) so stacked rows connect with straight wires.
//
// Do NOT override the parameters when instantiating this module; change
// gemm_asic_cfg.vh instead.
// ---------------------------------------------------------------------------
module ref_ProcessingElementRow
#(
    parameter P_ARRAY_COLS      = `GEMM_N,
    parameter P_DATA_WIDTH      = `GEMM_DW,
    parameter P_ROW_INDEX_WIDTH = `GEMM_RIW,
    parameter P_DATAPATH_RESET  = `GEMM_DP_RESET
)
(
`ifdef USE_POWER_PINS
    inout                                                           vccd1,   // OpenLane macro power pins
    inout                                                           vssd1,
`endif
    input                                                           i_clk,
    input                                                           i_rst_n,
    input                                                           i_weight_shift_en,
    input                                                           i_weight_load,
    input  [P_ARRAY_COLS*P_DATA_WIDTH-1:0]                          i_weight_shift_in,
    output [P_ARRAY_COLS*P_DATA_WIDTH-1:0]                          o_weight_shift_out,
    input  [P_DATA_WIDTH-1:0]                                       i_feature_value,
    input  [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]    i_partial_sum_vector,
    output [P_ARRAY_COLS*(P_ROW_INDEX_WIDTH+P_DATA_WIDTH*2)-1:0]    o_partial_sum_vector
);
localparam integer LP_PSW = P_ROW_INDEX_WIDTH + 2*P_DATA_WIDTH;

// feature travels left -> right, one register per PE
wire [P_DATA_WIDTH-1:0] w_feature_lane [P_ARRAY_COLS:0];
assign w_feature_lane[0] = i_feature_value;

genvar i;
generate
    for (i = 0; i < P_ARRAY_COLS; i = i + 1) begin : g_pe_column
        ref_ProcessingElement #(
            .P_DATA_WIDTH      (P_DATA_WIDTH),
            .P_ROW_INDEX_WIDTH (P_ROW_INDEX_WIDTH),
            .P_DATAPATH_RESET  (P_DATAPATH_RESET)
        ) u_processing_element (
            .i_clk              (i_clk),
            .i_rst_n            (i_rst_n),
            .i_weight_shift_en  (i_weight_shift_en),
            .i_weight_load      (i_weight_load),
            .i_weight_shift_in  (i_weight_shift_in [P_DATA_WIDTH*i +: P_DATA_WIDTH]),
            .o_weight_shift_out (o_weight_shift_out[P_DATA_WIDTH*i +: P_DATA_WIDTH]),
            .i_feature_value    (w_feature_lane[i]),
            .i_partial_sum      (i_partial_sum_vector[LP_PSW*i +: LP_PSW]),
            .o_feature_value    (w_feature_lane[i+1]),
            .o_partial_sum      (o_partial_sum_vector[LP_PSW*i +: LP_PSW])
        );
    end
endgenerate

endmodule
