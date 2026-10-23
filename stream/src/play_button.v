// Tang Nano 20K S1 (KEY_S1): active high with a board-level pulldown.
// A new event is issued only after a stable 20 ms press. Releasing the key
// for 20 ms rearms it, so contact bounce and a held key cannot retrigger.
module play_button #(
    parameter integer DEBOUNCE_CYCLES = 660000
)(
    input wire clk33,
    input wire rst,
    input wire key_raw,
    output wire press_pulse
);
    reg press_pulse_r = 1'b0;
    assign press_pulse = press_pulse_r;
    reg key_meta = 1'b0;
    reg key_sync = 1'b0;
    reg key_stable = 1'b0;
    reg [19:0] stable_count = 20'd0;

    always @(posedge clk33) begin
        key_meta <= key_raw;
        key_sync <= key_meta;
        press_pulse_r <= 1'b0;
        if (rst) begin
            key_stable <= 1'b0;
            stable_count <= 20'd0;
        end else if (key_sync == key_stable) begin
            stable_count <= 20'd0;
        end else if (stable_count == DEBOUNCE_CYCLES - 1) begin
            key_stable <= key_sync;
            stable_count <= 20'd0;
            if (key_sync)
                press_pulse_r <= 1'b1;
        end else begin
            stable_count <= stable_count + 20'd1;
        end
    end
endmodule
