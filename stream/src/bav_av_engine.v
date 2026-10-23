// BAV video/audio sink. All logic is clocked by the LCD's 33 MHz pixel clock.
// The caller supplies validated BAV record bytes and may stall at boundaries.
module bav_av_engine (
    input wire clk33,
    input wire rst,
    input wire idle,
    input wire video_valid,
    input wire [13:0] video_offset,
    input wire [7:0] video_byte,
    input wire audio_valid,
    input wire [7:0] audio_byte,
    input wire frame_done,
    input wire [31:0] frame_index,
    input wire end_of_stream,
    output wire frame_slot_ready,
    output wire audio_ready,
    output wire lcd_hs,
    output wire lcd_vs,
    output wire lcd_de,
    output wire [4:0] lcd_r,
    output wire [5:0] lcd_g,
    output wire [4:0] lcd_b,
    output reg HP_BCK,
    output reg HP_WS,
    output reg HP_DIN,
    output wire PA_EN,
    output reg [31:0] displayed_frame,
    output reg audio_underrun,
    output reg video_late,
    output reg playback_finished
);
    // Two 9,600-byte frame buffers. A bank is only freed after VSYNC selects
    // the other bank; the producer cannot overwrite the visible picture.
    reg [7:0] frame0 [0:9599];
    reg [7:0] frame1 [0:9599];
    reg [7:0] frame0_q, frame1_q;
    reg [1:0] bank_ready = 2'b00;
    reg write_bank = 1'b0;
    reg front_bank = 1'b0;
    reg first_loaded = 1'b0;
    reg playing = 1'b0;
    assign frame_slot_ready = !bank_ready[write_bank];

    always @(posedge clk33) begin
        if (video_valid && video_offset < 14'd9600) begin
            if (write_bank)
                frame1[video_offset] <= video_byte;
            else
                frame0[video_offset] <= video_byte;
        end
    end

    // 4,096-byte FIFO gives about 87 ms of PCM coverage at 46,875 samples/s.
    // Pointers carry an extra wrap bit for exact full/empty detection.
    reg [7:0] audio_fifo [0:4095];
    reg [12:0] wr_ptr = 13'd0;
    reg [12:0] rd_ptr = 13'd0;
    reg [7:0] fetched_pcm = 8'd128;
    wire fifo_empty = (wr_ptr == rd_ptr);
    wire fifo_full = (wr_ptr[11:0] == rd_ptr[11:0]) &&
                     (wr_ptr[12] != rd_ptr[12]);
    // The parser registers audio_valid, one clock after accepting input.
    // Reserve one credit for that already-accepted byte.
    wire [12:0] wr_ptr_plus1 = wr_ptr + 13'd1;
    wire fifo_almost_full = (wr_ptr_plus1[11:0] == rd_ptr[11:0]) &&
                            (wr_ptr_plus1[12] != rd_ptr[12]);
    assign audio_ready = !fifo_full && !fifo_almost_full;
    always @(posedge clk33) begin
        if (audio_valid && !fifo_full)
            audio_fifo[wr_ptr[11:0]] <= audio_byte;
    end
    always @(posedge clk33 or posedge rst) begin
        if (rst)
            fetched_pcm <= 8'd128;
        else if (audio_prefetch)
            fetched_pcm <= fifo_empty ? 8'd128 : audio_fifo[rd_ptr[11:0]];
    end

    wire hs_raw, vs_raw, de_raw;
    wire [9:0] x_raw, y_raw;
    vga_timing raster (
        .clk(clk33), .rst(rst), .hs(hs_raw), .vs(vs_raw),
        .de(de_raw), .active_x(x_raw), .active_y(y_raw)
    );
    wire in_picture = (x_raw >= 10'd80) && (x_raw < 10'd720) &&
                      (y_raw < 10'd480);
    wire [9:0] local_x = x_raw - 10'd80;
    wire [7:0] source_y = y_raw[8:1];
    wire [5:0] byte_x = local_x[9:4];
    wire [13:0] frame_byte = ({6'd0, source_y} << 5) +
                             ({6'd0, source_y} << 3) +
                             {8'd0, byte_x};
    wire [13:0] read_addr = in_picture ? frame_byte : 14'd0;
    reg [2:0] pixel_bit = 3'd0;
    reg in_picture_q = 1'b0;
    reg ready_pixel_q = 1'b0;
    reg de_q = 1'b0, hs_q = 1'b0, vs_q = 1'b0;
    // A 60 x 60 white play triangle at the screen center shows that S1 can
    // start (or replay) the clip. Coordinates are pipelined with video RAM.
    wire [9:0] icon_dx = x_raw - 10'd370;
    wire [9:0] icon_dy = y_raw - 10'd210;
    wire ready_triangle = (x_raw >= 10'd370) && (x_raw < 10'd430) &&
                          (y_raw >= 10'd210) && (y_raw < 10'd270) &&
                          (icon_dy >= (icon_dx >> 1)) &&
                          (icon_dy < (10'd60 - (icon_dx >> 1)));
    always @(posedge clk33) begin
        frame0_q <= frame0[read_addr];
        frame1_q <= frame1[read_addr];
        pixel_bit <= local_x[3:1];
        in_picture_q <= in_picture;
        ready_pixel_q <= idle && ready_triangle;
        de_q <= de_raw;
        hs_q <= hs_raw;
        vs_q <= vs_raw;
    end
    wire [7:0] visible_byte = front_bank ? frame1_q : frame0_q;
    wire white_pixel = ready_pixel_q ||
                       (first_loaded && in_picture_q &&
                        visible_byte[3'd7 - pixel_bit]);
    assign lcd_de = de_q;
    assign lcd_hs = hs_q;
    assign lcd_vs = vs_q;
    assign {lcd_r, lcd_g, lcd_b} = (de_q && white_pixel) ? 16'hffff : 16'h0000;

    // Exact-rate I2S from 33 MHz: 11 system clocks per BCLK half period,
    // 32 BCLK periods per left+right sample -> 46,875 samples per second.
    reg [3:0] half_count = 4'd0;
    reg [4:0] bit_slot = 5'd0;
    reg [15:0] sample_hold = 16'd0;
    localparam integer PCM_SHIFT = 6;
    wire [4:0] next_slot = bit_slot + 5'd1;
    wire [3:0] sample_bit = 4'd0 - next_slot[3:0];
    wire audio_prefetch = playing && (half_count == 4'd10) && HP_BCK &&
                          (bit_slot == 5'd30);
    wire sample_tick = playing && (half_count == 4'd10) && HP_BCK &&
                       (bit_slot == 5'd31);
    wire signed [8:0] pcm_diff = $signed({1'b0, fetched_pcm}) - 9'sd128;
    reg [15:0] startup_count = 16'd0;
    assign PA_EN = playing && (startup_count >= 16'd33000) && !rst;
    reg [10:0] samples_left = 11'd1562;
    reg sample_parity = 1'b0;
    reg frame_pending = 1'b0;
    reg vs_prev = 1'b0;

    always @(posedge clk33 or posedge rst) begin
        if (rst) begin
            bank_ready <= 2'b00;
            write_bank <= 1'b0;
            front_bank <= 1'b0;
            first_loaded <= 1'b0;
            playing <= 1'b0;
            wr_ptr <= 13'd0;
            rd_ptr <= 13'd0;
            half_count <= 4'd0;
            bit_slot <= 5'd0;
            HP_BCK <= 1'b0;
            HP_WS <= 1'b0;
            HP_DIN <= 1'b0;
            sample_hold <= 16'd0;
            startup_count <= 16'd0;
            samples_left <= 11'd1562;
            sample_parity <= 1'b0;
            frame_pending <= 1'b0;
            vs_prev <= 1'b0;
            displayed_frame <= 32'd0;
            audio_underrun <= 1'b0;
            video_late <= 1'b0;
            playback_finished <= 1'b0;
        end else begin
            if (audio_valid && !fifo_full)
                wr_ptr <= wr_ptr + 13'd1;
            if (audio_prefetch) begin
                if (!fifo_empty)
                    rd_ptr <= rd_ptr + 13'd1;
                else if (end_of_stream) begin
                    playing <= 1'b0;
                    playback_finished <= 1'b1;
                end else begin
                    audio_underrun <= 1'b1;
                end
            end
            if (frame_done) begin
                bank_ready[write_bank] <= 1'b1;
                write_bank <= ~write_bank;
                if (!first_loaded) begin
                    first_loaded <= 1'b1;
                    front_bank <= write_bank;
                    displayed_frame <= frame_index;
                end else if (!playing) begin
                    playing <= 1'b1;
                end
            end
            vs_prev <= vs_raw;
            if (playing && vs_raw && !vs_prev && frame_pending &&
                bank_ready[~front_bank]) begin
                bank_ready[front_bank] <= 1'b0;
                front_bank <= ~front_bank;
                displayed_frame <= displayed_frame + 32'd1;
                frame_pending <= 1'b0;
            end
            if (startup_count < 16'd33000)
                startup_count <= startup_count + 16'd1;
            if (half_count == 4'd10) begin
                half_count <= 4'd0;
                HP_BCK <= ~HP_BCK;
                if (HP_BCK) begin
                    bit_slot <= next_slot;
                    HP_WS <= next_slot[4];
                    HP_DIN <= sample_hold[sample_bit];
                    if (sample_tick) begin
                        sample_hold <= {{7{pcm_diff[8]}}, pcm_diff} << PCM_SHIFT;
                        if (samples_left == 11'd1) begin
                            samples_left <= sample_parity ? 11'd1562 : 11'd1563;
                            sample_parity <= ~sample_parity;
                            if (frame_pending)
                                video_late <= 1'b1;
                            frame_pending <= 1'b1;
                        end else begin
                            samples_left <= samples_left - 11'd1;
                        end
                    end
                end
            end else begin
                half_count <= half_count + 4'd1;
            end
        end
    end
endmodule
