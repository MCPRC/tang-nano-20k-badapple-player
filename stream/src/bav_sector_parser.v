// Sequential BAV1 sector parser. One accepted byte per clock, in file order.
// in_last must mark the final byte of every 512-byte sector.
module bav_sector_parser (
    input  wire        clk,
    input  wire        rst,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [7:0]  in_byte,
    input  wire        in_last,
    input  wire        frame_slot_ready,
    input  wire        audio_ready,
    output reg         video_valid,
    output reg  [13:0] video_offset,
    output reg  [7:0]  video_byte,
    output reg         audio_valid,
    output reg  [7:0]  audio_byte,
    output reg         frame_done,
    output reg  [31:0] frame_index,
    output reg         header_ok,
    output reg         done,
    output reg  [7:0]  error
);
    // error bits: 0=header, 1=sector boundary, 2=index,
    // 3=audio count, 4=flags, 5=padding, 6=CRC.
    localparam [13:0] VIDEO_FIRST = 14'd12;
    localparam [13:0] VIDEO_LAST  = 14'd9611;
    localparam [13:0] AUDIO_FIRST = 14'd9612;
    localparam [13:0] RECORD_LAST = 14'd11263;

    reg [13:0] pos;
    reg [31:0] frame_count;
    reg [31:0] next_index;
    reg [31:0] stored_crc;
    reg [31:0] running_crc;

    wire [13:0] audio_last = next_index[0] ? 14'd11174 : 14'd11173;
    wire is_audio = header_ok && (pos >= AUDIO_FIRST) && (pos <= audio_last);
    wire is_video = header_ok && (pos >= VIDEO_FIRST) && (pos <= VIDEO_LAST);
    wire final_record = (next_index == frame_count - 32'd1);
    wire [7:0] expected_count_lo = next_index[0] ? 8'h1B : 8'h1A;
    wire [7:0] expected_flags_lo = final_record ? 8'h01 : 8'h00;
    assign in_ready = (error == 8'b0) && !done &&
        ((!header_ok) || (pos != 14'd0) || frame_slot_ready) &&
        ((!is_audio) || audio_ready);
    wire accept = in_valid && in_ready;
    wire bad_last = in_last != (pos[8:0] == 9'd511);

    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0] data;
        reg [31:0] c;
        integer i;
        begin
            c = crc_in ^ {24'b0, data};
            for (i = 0; i < 8; i = i + 1)
                c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
            crc32_byte = c;
        end
    endfunction

    // Fixed BAV1 display/audio format from media/README.md. Frame count and
    // PCM total are intentionally variable, so the same parser accepts clips
    // of different duration that use the same 320x240/30fps/46875Hz format.
    function bad_header_fixed_byte;
        input [13:0] offset;
        input [7:0] data;
        begin
            bad_header_fixed_byte = 1'b0;
            case (offset)
                14'd0:  bad_header_fixed_byte = data != "B";
                14'd1:  bad_header_fixed_byte = data != "A";
                14'd2:  bad_header_fixed_byte = data != "V";
                14'd3:  bad_header_fixed_byte = data != "1";
                14'd4:  bad_header_fixed_byte = data != 8'h00;
                14'd5:  bad_header_fixed_byte = data != 8'h02;
                14'd6:  bad_header_fixed_byte = data != 8'h01;
                14'd7:  bad_header_fixed_byte = data != 8'h00;
                14'd8:  bad_header_fixed_byte = data != 8'h40;
                14'd9:  bad_header_fixed_byte = data != 8'h01;
                14'd10: bad_header_fixed_byte = data != 8'hF0;
                14'd11: bad_header_fixed_byte = data != 8'h00;
                14'd12: bad_header_fixed_byte = data != 8'h1E;
                14'd13, 14'd14, 14'd15: bad_header_fixed_byte = data != 8'h00;
                14'd16: bad_header_fixed_byte = data != 8'h01;
                14'd17, 14'd18, 14'd19: bad_header_fixed_byte = data != 8'h00;
                14'd20: bad_header_fixed_byte = data != 8'h1B;
                14'd21: bad_header_fixed_byte = data != 8'hB7;
                14'd22, 14'd23: bad_header_fixed_byte = data != 8'h00;
                14'd28: bad_header_fixed_byte = data != 8'h16;
                14'd29: bad_header_fixed_byte = data != 8'h00;
                14'd30: bad_header_fixed_byte = data != 8'h80;
                14'd31: bad_header_fixed_byte = data != 8'h25;
                14'd32: bad_header_fixed_byte = data != 8'h0C;
                14'd33: bad_header_fixed_byte = data != 8'h00;
                14'd34, 14'd35: bad_header_fixed_byte = data != 8'h01;
                default: begin
                    if (offset >= 14'd48 && offset <= 14'd511)
                        bad_header_fixed_byte = data != 8'h00;
                end
            endcase
        end
    endfunction

    wire header_byte_bad = bad_header_fixed_byte(pos, in_byte);
    wire [7:0] record_error =
        ((pos == 14'd0 && in_byte != next_index[7:0]) ||
         (pos == 14'd1 && in_byte != next_index[15:8]) ||
         (pos == 14'd2 && in_byte != next_index[23:16]) ||
         (pos == 14'd3 && in_byte != next_index[31:24])) ? 8'h04 :
        ((pos == 14'd4 && in_byte != expected_count_lo) ||
         (pos == 14'd5 && in_byte != 8'h06)) ? 8'h08 :
        ((pos == 14'd6 && in_byte != expected_flags_lo) ||
         (pos == 14'd7 && in_byte != 8'h00)) ? 8'h10 :
        ((pos > audio_last && pos <= RECORD_LAST && in_byte != 8'h00)) ? 8'h20 :
        8'h00;

    always @(posedge clk) begin
        if (rst) begin
            pos          <= 14'd0;
            frame_count  <= 32'd0;
            next_index   <= 32'd0;
            stored_crc   <= 32'd0;
            running_crc  <= 32'hFFFFFFFF;
            video_valid  <= 1'b0;
            video_offset <= 14'd0;
            video_byte   <= 8'd0;
            audio_valid  <= 1'b0;
            audio_byte   <= 8'd0;
            frame_done   <= 1'b0;
            frame_index  <= 32'd0;
            header_ok    <= 1'b0;
            done         <= 1'b0;
            error        <= 8'd0;
        end else begin
            video_valid <= 1'b0;
            audio_valid <= 1'b0;
            frame_done  <= 1'b0;
            if (accept) begin
                if (bad_last)
                    error <= error | 8'h02;
                if (!header_ok) begin
                    if (header_byte_bad)
                        error <= error | 8'h01 | (bad_last ? 8'h02 : 8'h00);
                    case (pos)
                        14'd24: frame_count[7:0]   <= in_byte;
                        14'd25: frame_count[15:8]  <= in_byte;
                        14'd26: frame_count[23:16] <= in_byte;
                        14'd27: frame_count[31:24] <= in_byte;
                        default: begin end
                    endcase
                    if (pos == 14'd511) begin
                        if (frame_count == 32'd0)
                            error <= error | 8'h01 | (bad_last ? 8'h02 : 8'h00);
                        else if (!header_byte_bad && !bad_last) begin
                            header_ok <= 1'b1;
                            pos <= 14'd0;
                        end
                    end else
                        pos <= pos + 14'd1;
                end else begin
                    if (record_error != 8'h00)
                        error <= error | record_error | (bad_last ? 8'h02 : 8'h00);
                    case (pos)
                        14'd8:  stored_crc[7:0]   <= in_byte;
                        14'd9:  stored_crc[15:8]  <= in_byte;
                        14'd10: stored_crc[23:16] <= in_byte;
                        14'd11: stored_crc[31:24] <= in_byte;
                        default: begin end
                    endcase
                    if (is_video) begin
                        video_valid  <= 1'b1;
                        video_offset <= pos - VIDEO_FIRST;
                        video_byte   <= in_byte;
                        running_crc  <= crc32_byte(running_crc, in_byte);
                    end else if (is_audio) begin
                        audio_valid  <= 1'b1;
                        audio_byte   <= in_byte;
                        running_crc  <= crc32_byte(running_crc, in_byte);
                    end
                    if (pos == RECORD_LAST) begin
                        if ((~running_crc) != stored_crc) begin
                            error <= error | 8'h40 | (bad_last ? 8'h02 : 8'h00);
                        end else if (record_error == 8'h00 && !bad_last) begin
                            frame_done  <= 1'b1;
                            frame_index <= next_index;
                            next_index  <= next_index + 32'd1;
                            if (final_record)
                                done <= 1'b1;
                        end
                        running_crc <= 32'hFFFFFFFF;
                        pos <= 14'd0;
                    end else
                        pos <= pos + 14'd1;
                end
            end
        end
    end
endmodule
