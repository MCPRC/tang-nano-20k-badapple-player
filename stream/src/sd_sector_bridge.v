// Tang Nano 20K read-only SD sector bridge, using Sipeed/NESTang sd_reader.
// Request and byte stream are in 33 MHz AV domain. Card reader is in 81 MHz.
// The 512-byte dual-clock RAM is never read while it is being written.
module sd_sector_bridge #(
    parameter [31:0] FILE_START_LBA = 32'd57264
)(
    input wire clk_sd,
    input wire rstn_sd,
    input wire clk_av,
    input wire rstn_av,
    input wire req_valid,
    input wire [31:0] req_lba,
    output wire req_ready,
    output wire data_valid,
    output wire [7:0] data_byte,
    input wire data_ready,
    output wire data_last,
    output reg data_error,
    output wire sd_clk,
    inout wire sd_cmd,
    input wire sd_dat0
);

    // AV -> SD toggle handshake. req_lba_hold remains stable until the
    // request completes, so the 81 MHz side can sample it after toggle sync.
    reg req_toggle;
    reg [31:0] req_lba_hold;
    reg done_meta, done_sync, done_seen;
    reg [1:0] av_state;
    localparam [1:0] AV_IDLE=0, AV_WAIT=1, AV_PRIME=2, AV_STREAM=3;
    reg [8:0] byte_index;
    reg [7:0] ram_read_data;
    reg [8:0] ram_read_addr;
    reg ram_read_en;
    reg [7:0] sector_ram [0:511];
    wire done_toggle;
    wire sd_error_hold;

    assign req_ready = av_state == AV_IDLE;
    assign data_valid = av_state == AV_STREAM;
    assign data_byte = ram_read_data;
    assign data_last = (av_state == AV_STREAM) && (byte_index == 9'd511);

    always @(posedge clk_av) begin
        if (ram_read_en) ram_read_data <= sector_ram[ram_read_addr];
    end

    always @(posedge clk_av or negedge rstn_av) begin
        if (!rstn_av) begin
            req_toggle <= 0;
            req_lba_hold <= 0;
            done_meta <= 0;
            done_sync <= 0;
            done_seen <= 0;
            av_state <= AV_IDLE;
            byte_index <= 0;
            ram_read_addr <= 0;
            ram_read_en <= 0;
            data_error <= 0;
        end else begin
            done_meta <= done_toggle;
            done_sync <= done_meta;
            ram_read_en <= 0;
            case (av_state)
                AV_IDLE: if (req_valid) begin
                    req_lba_hold <= req_lba;
                    req_toggle <= ~req_toggle;
                    data_error <= 0;
                    av_state <= AV_WAIT;
                end
                AV_WAIT: if (done_sync != done_seen) begin
                    done_seen <= done_sync;
                    data_error <= sd_error_hold;
                    byte_index <= 0;
                    ram_read_addr <= 0;
                    ram_read_en <= 1;
                    av_state <= AV_PRIME;
                end
                AV_PRIME: begin
                    // ram_read_en from prior cycle causes byte 0 to be read.
                    av_state <= AV_STREAM;
                end
                AV_STREAM: if (data_ready) begin
                    if (byte_index == 9'd511) begin
                        av_state <= AV_IDLE;
                    end else begin
                        byte_index <= byte_index + 1'b1;
                        ram_read_addr <= byte_index + 1'b1;
                        ram_read_en <= 1;
                        av_state <= AV_PRIME;
                    end
                end
            endcase
        end
    end

    reg req_meta, req_sync, req_seen;
    reg [1:0] sd_state;
    localparam [1:0] SD_IDLE=0, SD_START=1, SD_WAIT=2;
    reg [31:0] sd_lba;
    reg sd_rstart;
    reg sd_done_toggle;
    reg sd_error;
    reg [1:0] retry_count;
    reg [9:0] bytes_seen;
    reg [27:0] read_watchdog;
    reg [10:0] reader_reset_hold;
    wire reader_rstn = rstn_sd && (reader_reset_hold == 0);
    wire [3:0] card_stat;
    wire [1:0] card_type;
    wire sd_rbusy, sd_rdone, sd_outen;
    wire [8:0] sd_outaddr;
    wire [7:0] sd_outbyte;
    wire sd_crc_seen, sd_crc_ok;
    wire [15:0] sd_crc_calc, sd_crc_recv;
    assign done_toggle = sd_done_toggle;
    assign sd_error_hold = sd_error;

    sd_reader #(.CLK_DIV(3'd2), .SIMULATE(0)) reader(
        .rstn(reader_rstn), .clk(clk_sd),
        .sdclk(sd_clk), .sdcmd(sd_cmd), .sddat0(sd_dat0),
        .card_stat(card_stat), .card_type(card_type),
        .rstart(sd_rstart), .rsector(sd_lba), .rbusy(sd_rbusy), .rdone(sd_rdone),
        .outen(sd_outen), .outaddr(sd_outaddr), .outbyte(sd_outbyte),
        .data_crc_seen(sd_crc_seen), .data_crc_ok(sd_crc_ok),
        .data_crc_calc(sd_crc_calc), .data_crc_recv(sd_crc_recv)
    );

    always @(posedge clk_sd) begin
        if (sd_outen) sector_ram[sd_outaddr] <= sd_outbyte;
    end

    always @(posedge clk_sd or negedge rstn_sd) begin
        if (!rstn_sd) begin
            req_meta <= 0;
            req_sync <= 0;
            req_seen <= 0;
            sd_state <= SD_IDLE;
            sd_lba <= 0;
            sd_rstart <= 0;
            sd_done_toggle <= 0;
            sd_error <= 0;
            retry_count <= 0;
            bytes_seen <= 0;
            read_watchdog <= 0;
            reader_reset_hold <= 0;
        end else begin
            req_meta <= req_toggle;
            req_sync <= req_meta;
            sd_rstart <= 0;
            if (reader_reset_hold != 0)
                reader_reset_hold <= reader_reset_hold - 1'b1;
            if (sd_outen && sd_state == SD_WAIT)
                bytes_seen <= bytes_seen + 1'b1;
            case (sd_state)
                SD_IDLE: if (req_sync != req_seen && card_stat == 4'd8) begin
                    req_seen <= req_sync;
                    sd_lba <= FILE_START_LBA + req_lba_hold;
                    retry_count <= 0;
                    sd_state <= SD_START;
                end
                SD_START: begin
                    bytes_seen <= 0;
                    read_watchdog <= 0;
                    sd_rstart <= 1;
                    sd_state <= SD_WAIT;
                end
                SD_WAIT: if (sd_rdone) begin
                    if (sd_crc_seen && sd_crc_ok && bytes_seen == 10'd512) begin
                        sd_error <= 0;
                        sd_done_toggle <= ~sd_done_toggle;
                        sd_state <= SD_IDLE;
                    end else if (retry_count < 2'd3) begin
                        retry_count <= retry_count + 1'b1;
                        sd_state <= SD_START;
                    end else begin
                        sd_error <= 1;
                        sd_done_toggle <= ~sd_done_toggle;
                        sd_state <= SD_IDLE;
                    end
                end else if (read_watchdog >= 28'd162000000) begin
                    // Abort a stuck CMD17 after 2 seconds, report an error,
                    // and reset/reinitialize the card controller.
                    sd_error <= 1;
                    sd_done_toggle <= ~sd_done_toggle;
                    reader_reset_hold <= 11'd1023;
                    sd_state <= SD_IDLE;
                end else read_watchdog <= read_watchdog + 1'b1;
            endcase
        end
    end
endmodule
