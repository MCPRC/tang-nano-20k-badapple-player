// First TF-card playback integration for Tang Nano 20K revision 3921.
// The SD bridge currently assumes BADAPPLE.BAV occupies consecutive sectors
// beginning at physical LBA 57264. The FAT allocation must be audited before
// considering this generally usable with another copy/card.
module top (
    input wire clk,
    input wire rst,
    input wire play_key,
    output wire lcd_dclk,
    output wire lcd_hs,
    output wire lcd_vs,
    output wire lcd_de,
    output wire [4:0] lcd_r,
    output wire [5:0] lcd_g,
    output wire [4:0] lcd_b,
    output wire HP_BCK,
    output wire HP_WS,
    output wire HP_DIN,
    output wire PA_EN,
    output wire sd_clk,
    inout wire sd_cmd,
    input wire sd_dat0,
    output wire sd_dat1,
    output wire sd_dat2,
    output wire sd_dat3,
    output wire [1:0] led
);
    wire clk33, clk81, sd_pll_lock;
    video_pll av_pll (.clkin(clk), .clkout(clk33));
    sd_pll card_pll (.clkin(clk), .clkout(clk81), .lock(sd_pll_lock));
    assign lcd_dclk = clk33;
    assign sd_dat1 = 1'b1;
    assign sd_dat2 = 1'b1;
    assign sd_dat3 = 1'b1;

    // S1 starts playback; a later S1 press starts again at frame/audio zero.
    // Holding both playback domains in reset for 2 ms also flushes an
    // interrupted sector transfer before the SD host reinitializes the card.
    wire key_press;
    play_button start_key (
        .clk33(clk33), .rst(rst), .key_raw(play_key),
        .press_pulse(key_press)
    );
    reg play_active = 1'b0;
    reg [16:0] restart_count = 17'd0;
    always @(posedge clk33) begin
        if (rst) begin
            play_active <= 1'b0;
            restart_count <= 17'd0;
        end else if (key_press) begin
            play_active <= 1'b1;
            restart_count <= 17'd66000;
        end else if (restart_count != 17'd0) begin
            restart_count <= restart_count - 17'd1;
        end
    end
    wire restart_reset = key_press || (restart_count != 17'd0);

    reg [19:0] sd_startup = 20'd0;
    always @(posedge clk81 or negedge sd_pll_lock) begin
        if (!sd_pll_lock) sd_startup <= 20'd0;
        else if (!sd_startup[19]) sd_startup <= sd_startup + 20'd1;
    end
    reg [15:0] av_startup = 16'd0;
    always @(posedge clk33) begin
        if (rst) av_startup <= 16'd0;
        else if (!av_startup[15]) av_startup <= av_startup + 16'd1;
    end
    // Assertion can cross domains asynchronously; release is synchronized to
    // each local clock. Both request-toggle endpoints reset together.
    wire sd_reset_request = !sd_pll_lock || !sd_startup[19] || rst || restart_reset;
    wire av_reset_request = !av_startup[15] || rst || restart_reset;
    reg [2:0] sd_reset_release = 3'b000;
    reg [2:0] av_reset_release = 3'b000;
    always @(posedge clk81 or posedge sd_reset_request) begin
        if (sd_reset_request) sd_reset_release <= 3'b000;
        else sd_reset_release <= {sd_reset_release[1:0], 1'b1};
    end
    always @(posedge clk33 or posedge av_reset_request) begin
        if (av_reset_request) av_reset_release <= 3'b000;
        else av_reset_release <= {av_reset_release[1:0], 1'b1};
    end
    wire rstn_sd = sd_reset_release[2];
    wire rstn_av = av_reset_release[2];
    wire rst_av = !rstn_av;

    wire req_valid, req_ready;
    reg [31:0] logical_lba = 32'd0;
    reg sector_in_flight = 1'b0;
    wire data_valid, data_ready, data_last;
    wire [7:0] data_byte;
    wire sd_data_error;
    wire parser_ready, header_ok, parser_done;
    wire [7:0] parser_error;
    assign data_ready = sector_in_flight && parser_ready && !sd_data_error;
    assign req_valid = play_active && rstn_av && !sector_in_flight && !parser_done &&
                       (parser_error == 8'd0) && !sd_data_error && parser_ready;
    always @(posedge clk33 or posedge rst_av) begin
        if (rst_av) begin
            logical_lba <= 32'd0;
            sector_in_flight <= 1'b0;
        end else begin
            if (req_valid && req_ready) begin
                sector_in_flight <= 1'b1;
                logical_lba <= logical_lba + 32'd1;
            end
            if (data_valid && data_ready && data_last)
                sector_in_flight <= 1'b0;
        end
    end

    sd_sector_bridge card (
        .clk_sd(clk81), .clk_av(clk33),
        .rstn_sd(rstn_sd), .rstn_av(rstn_av),
        .req_valid(req_valid), .req_lba(logical_lba), .req_ready(req_ready),
        .data_valid(data_valid), .data_byte(data_byte),
        .data_ready(data_ready), .data_last(data_last),
        .data_error(sd_data_error),
        .sd_clk(sd_clk), .sd_cmd(sd_cmd), .sd_dat0(sd_dat0)
    );

    wire video_valid, audio_valid, frame_done;
    wire [13:0] video_offset;
    wire [7:0] video_byte, audio_byte;
    wire [31:0] frame_index;
    wire frame_slot_ready, audio_ready;
    bav_sector_parser parser (
        .clk(clk33), .rst(rst_av),
        .in_valid(data_valid && sector_in_flight && !sd_data_error),
        .in_ready(parser_ready), .in_byte(data_byte), .in_last(data_last),
        .frame_slot_ready(frame_slot_ready), .audio_ready(audio_ready),
        .video_valid(video_valid), .video_offset(video_offset),
        .video_byte(video_byte), .audio_valid(audio_valid),
        .audio_byte(audio_byte), .frame_done(frame_done),
        .frame_index(frame_index), .header_ok(header_ok),
        .done(parser_done), .error(parser_error)
    );

    wire [31:0] displayed_frame;
    wire audio_underrun, video_late, playback_finished;
    bav_av_engine av (
        .clk33(clk33), .rst(rst_av),
        .idle(!play_active || playback_finished),
        .video_valid(video_valid), .video_offset(video_offset),
        .video_byte(video_byte), .audio_valid(audio_valid),
        .audio_byte(audio_byte), .frame_done(frame_done),
        .frame_index(frame_index), .end_of_stream(parser_done),
        .frame_slot_ready(frame_slot_ready),
        .audio_ready(audio_ready),
        .lcd_hs(lcd_hs), .lcd_vs(lcd_vs), .lcd_de(lcd_de),
        .lcd_r(lcd_r), .lcd_g(lcd_g), .lcd_b(lcd_b),
        .HP_BCK(HP_BCK), .HP_WS(HP_WS), .HP_DIN(HP_DIN), .PA_EN(PA_EN),
        .displayed_frame(displayed_frame),
        .audio_underrun(audio_underrun), .video_late(video_late),
        .playback_finished(playback_finished)
    );

    // On-board LEDs are active low. LED0 changes every 32 displayed frames;
    // LED1 indicates a parser error or playback starvation.
    assign led[0] = ~displayed_frame[5];
    assign led[1] = ~(sd_data_error || parser_error != 8'd0 ||
                      audio_underrun || video_late);
endmodule
