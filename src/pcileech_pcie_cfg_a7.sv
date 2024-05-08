//
// PCILeech FPGA.
//
// PCIe configuration module - CFG handling for Artix-7.
//
// (c) Ulf Frisk, 2018-2024
// Author: Ulf Frisk, pcileech@frizk.net
//

`timescale 1ns / 1ps
`include "pcileech_header.svh"

module pcileech_pcie_cfg_a7(
    input                   rst,
    input                   clk_sys,
    input                   clk_pcie,
    IfPCIeFifoCfg.mp_pcie   dfifo,
    IfPCIeSignals.mpm       ctx,
    IfAXIS128.source        tlps_static,
    output [15:0]           pcie_id,
    output wire [31:0]      base_address_register
    );

    // ----------------------------------------------------
    // TickCount64
    // ----------------------------------------------------
    
    time tickcount64 = 0;
    always @ ( posedge clk_pcie )
        tickcount64 <= tickcount64 + 1;
    
    // ----------------------------------------------------------------------------
    // Convert received CFG data from FT601 to PCIe clock domain
    // FIFO depth: 512 / 64-bits
    // ----------------------------------------------------------------------------
    reg             in_rden;
    wire [63:0]     in_dout;
    wire            in_empty;
    wire            in_valid;
    
    reg [63:0]      in_data64;
    wire [31:0]     in_data32   = in_data64[63:32];
    wire [15:0]     in_data16   = in_data64[31:16];
    wire [3:0]      in_type     = in_data64[15:12];
	
    fifo_64_64 i_fifo_pcie_cfg_tx(
        .rst            ( rst                   ),
        .wr_clk         ( clk_sys               ),
        .rd_clk         ( clk_pcie              ),
        .din            ( dfifo.tx_data         ),
        .wr_en          ( dfifo.tx_valid        ),
        .rd_en          ( in_rden               ),
        .dout           ( in_dout               ),
        .full           (                       ),
        .empty          ( in_empty              ),
        .valid          ( in_valid              )
    );
    
    // ------------------------------------------------------------------------
    // Convert received CFG from PCIe core and transmit onwards to FT601
    // FIFO depth: 512 / 64-bits.
    // ------------------------------------------------------------------------
    reg             out_wren;
    reg [31:0]      out_data;
    wire            pcie_cfg_rx_almost_full;
    
    fifo_32_32_clk2 i_fifo_pcie_cfg_rx(
        .rst            ( rst                   ),
        .wr_clk         ( clk_pcie              ),
        .rd_clk         ( clk_sys               ),
        .din            ( out_data              ),
        .wr_en          ( out_wren              ),
        .rd_en          ( dfifo.rx_rd_en        ),
        .dout           ( dfifo.rx_data         ),
        .full           (                       ),
        .almost_full    ( pcie_cfg_rx_almost_full ),
        .empty          (                       ),
        .valid          ( dfifo.rx_valid        )
    );
    
    // ------------------------------------------------------------------------
    // REGISTER FILE: COMMON
    // ------------------------------------------------------------------------
    
    wire    [383:0]     ro;
    reg     [703:0]     rw;
    
    // special non-user accessible registers 
    reg                 rwi_cfg_mgmt_rd_en;
    reg                 rwi_cfg_mgmt_wr_en;
    reg                 rwi_cfgrd_valid;
    reg     [9:0]       rwi_cfgrd_addr;
    reg     [3:0]       rwi_cfgrd_byte_en;
    reg     [31:0]      rwi_cfgrd_data;
    reg                 rwi_tlp_static_valid;
    reg                 rwi_tlp_static_2nd;
    reg                 rwi_tlp_static_has_data;
    reg     [31:0]      rwi_count_cfgspace_status_cl;
    bit     [31:0]      base_address_register_reg;
	bit     [9:0]       next_cfg_task; // pasted from rogueskript
   
    // ------------------------------------------------------------------------
    // REGISTER FILE: READ-ONLY LAYOUT/SPECIFICATION
    // ------------------------------------------------------------------------
     
    // MAGIC
    assign base_address_register = base_address_register_reg;
    assign ro[15:0]     = 16'h2301;                     // +000: MAGIC
    // SPECIAL
    assign ro[16]       = ctx.cfg_mgmt_rd_en;           // +002: SPECIAL
    assign ro[17]       = ctx.cfg_mgmt_wr_en;           //
    assign ro[31:18]    = 0;                            //
    // SIZEOF / BYTECOUNT [little-endian]
    assign ro[63:32]    = $bits(ro) >> 3;               // +004: BYTECOUNT
    // PCIe CFG STATUS
    assign ro[71:64]    = ctx.cfg_bus_number;           // +008:
    assign ro[76:72]    = ctx.cfg_device_number;        //
    assign ro[79:77]    = ctx.cfg_function_number;      //
    // PCIe PL PHY
    assign ro[85:80]    = ctx.pl_ltssm_state;           // +00A
    assign ro[87:86]    = ctx.pl_rx_pm_state;           //
    assign ro[90:88]    = ctx.pl_tx_pm_state;           // +00B
    assign ro[93:91]    = ctx.pl_initial_link_width;    //
    assign ro[95:94]    = ctx.pl_lane_reversal_mode;    //
    assign ro[97:96]    = ctx.pl_sel_lnk_width;         // +00C
    assign ro[98]       = ctx.pl_phy_lnk_up;            //
    assign ro[99]       = ctx.pl_link_gen2_cap;         //
    assign ro[100]      = ctx.pl_link_partner_gen2_supported; //
    assign ro[101]      = ctx.pl_link_upcfg_cap;        //
    assign ro[102]      = ctx.pl_sel_lnk_rate;          //
    assign ro[103]      = ctx.pl_directed_change_done;  // +00D:
    assign ro[104]      = ctx.pl_received_hot_rst;      //
    assign ro[126:105]  = 0;                            //       SLACK
    assign ro[127]      = ctx.cfg_mgmt_rd_wr_done;      //
    // PCIe CFG MGMT
    assign ro[159:128]  = ctx.cfg_mgmt_do;              // +010:
    // PCIe CFG STATUS
    assign ro[175:160]  = ctx.cfg_command;              // +014:
    assign ro[176]      = ctx.cfg_aer_rooterr_corr_err_received;            // +016:
    assign ro[177]      = ctx.cfg_aer_rooterr_corr_err_reporting_en;        //
    assign ro[178]      = ctx.cfg_aer_rooterr_fatal_err_received;           //
    assign ro[179]      = ctx.cfg_aer_rooterr_fatal_err_reporting_en;       //
    assign ro[180]      = ctx.cfg_aer_rooterr_non_fatal_err_received;       //
    assign ro[181]      = ctx.cfg_aer_rooterr_non_fatal_err_reporting_en;   //
    assign ro[182]      = ctx.cfg_bridge_serr_en;                           //
    assign ro[183]      = ctx.cfg_received_func_lvl_rst;                    //
    assign ro[186:184]  = ctx.cfg_pcie_link_state;      // +017:
    assign ro[187]      = ctx.cfg_pmcsr_pme_en;         //
    assign ro[189:188]  = ctx.cfg_pmcsr_powerstate;     //
    assign ro[190]      = ctx.cfg_pmcsr_pme_status;     //
    assign ro[191]      = 0;                            //       SLACK
    assign ro[207:192]  = ctx.cfg_dcommand;             // +018:
    assign ro[223:208]  = ctx.cfg_dcommand2;            // +01A:
    assign ro[239:224]  = ctx.cfg_dstatus;              // +01C:
    assign ro[255:240]  = ctx.cfg_lcommand;             // +01E:
    assign ro[271:256]  = ctx.cfg_lstatus;              // +020:
    assign ro[287:272]  = ctx.cfg_status;               // +022:
    assign ro[293:288]  = ctx.tx_buf_av;                // +024:
    assign ro[294]      = ctx.tx_cfg_req;               //
    assign ro[295]      = ctx.tx_err_drop;              //
    assign ro[302:296]  = ctx.cfg_vc_tcvc_map;          // +025:
    assign ro[303]      = 0;                            //       SLACK
    assign ro[304]      = ctx.cfg_root_control_pme_int_en;              // +026:
    assign ro[305]      = ctx.cfg_root_control_syserr_corr_err_en;      //
    assign ro[306]      = ctx.cfg_root_control_syserr_fatal_err_en;     //
    assign ro[307]      = ctx.cfg_root_control_syserr_non_fatal_err_en; //
    assign ro[308]      = ctx.cfg_slot_control_electromech_il_ctl_pulse;//
    assign ro[309]      = ctx.cfg_to_turnoff;                           //
    assign ro[319:310]  = 0;                                            //       SLACK
    // PCIe INTERRUPT
    assign ro[327:320]  = ctx.cfg_interrupt_do;         // +028:
    assign ro[330:328]  = ctx.cfg_interrupt_mmenable;   // +029:
    assign ro[331]      = ctx.cfg_interrupt_msienable;  //
    assign ro[332]      = ctx.cfg_interrupt_msixenable; //
    assign ro[333]      = ctx.cfg_interrupt_msixfm;     //
    assign ro[334]      = ctx.cfg_interrupt_rdy;        //
    assign ro[335]      = 0;                            //       SLACK
    // CFG SPACE READ RESULT
    assign ro[345:336]  = rwi_cfgrd_addr;               // +02A:
    assign ro[346]      = 0;                            //       SLACK
    assign ro[347]      = rwi_cfgrd_valid;              //
    assign ro[351:348]  = rwi_cfgrd_byte_en;            //
    assign ro[383:352]  = rwi_cfgrd_data;               // +02C:
    // 0030 - 
    
    
    // ------------------------------------------------------------------------
    // INITIALIZATION/RESET BLOCK _AND_
    // REGISTER FILE: READ-WRITE LAYOUT/SPECIFICATION
    // ------------------------------------------------------------------------
    
    localparam integer  RWPOS_CFG_RD_EN                 = 16;
    localparam integer  RWPOS_CFG_WR_EN                 = 17;
    localparam integer  RWPOS_CFG_WAIT_COMPLETE         = 18;
    localparam integer  RWPOS_CFG_STATIC_TLP_TX_EN      = 19;
    localparam integer  RWPOS_CFG_CFGSPACE_STATUS_CL_EN = 20;
    localparam integer  RWPOS_CFG_CFGSPACE_COMMAND_EN   = 21;
    
    task pcileech_pcie_cfg_a7_initialvalues;        // task is non automatic
        begin
            out_wren <= 1'b0;
            
            rwi_cfg_mgmt_rd_en <= 1'b0;
            rwi_cfg_mgmt_wr_en <= 1'b0;
            base_address_register_reg <= 32'h00000000;
    
            // MAGIC
            rw[15:0]    <= 16'h6745;                // +000:
            // SPECIAL START TASK BLOCK (write 1 to start action)
            rw[16]      <= 0;                       // +002: CFG RD EN
            rw[17]      <= 0;                       //       CFG WR EN
            rw[18]      <= 0;                       //       WAIT FOR PCIe CFG SPACE RD/WR COMPLETION BEFORE ACCEPT NEW FIFO READ/WRITES
            rw[19]      <= 0;                       //       TLP_STATIC TX ENABLE
            rw[20]      <= 1;                       //       CFGSPACE_STATUS_REGISTER_AUTO_CLEAR [master abort flag]
            rw[21]      <= 0;                       //       CFGSPACE_COMMAND_REGISTER_AUTO_SET [bus master and other flags (set in rw[143:128] <= 16'h....;)]
            rw[31:22]   <= 0;                       //       RESERVED FUTURE
            // SIZEOF / BYTECOUNT [little-endian]
            rw[63:32]   <= $bits(rw) >> 3;          // +004: bytecount [little endian]
            // DSN
            rw[127:64]  <= 64'h0000000101000A35;    // +008: cfg_dsn
            // PCIe CFG MGMT
            rw[159:128] <= 0;                       // +010: cfg_mgmt_di
            rw[169:160] <= 0;                       // +014: cfg_mgmt_dwaddr
            rw[170]     <= 0;                       //       cfg_mgmt_wr_readonly
            rw[171]     <= 0;                       //       cfg_mgmt_wr_rw1c_as_rw
            rw[175:172] <= 4'hf;                    //       cfg_mgmt_byte_en
            // PCIe PL PHY
            rw[176]     <= 0;                       // +016: pl_directed_link_auton
            rw[178:177] <= 0;                       //       pl_directed_link_change
            rw[179]     <= 0;                       //       pl_directed_link_speed 
            rw[181:180] <= 0;                       //       pl_directed_link_width            
            rw[182]     <= 1;                       //       pl_upstream_prefer_deemph
            rw[183]     <= 0;                       //       pl_transmit_hot_rst
            rw[184]     <= 0;                       // +017: pl_downstream_deemph_source
            rw[191:185] <= 0;                       //       SLACK  
            // PCIe INTERRUPT
            rw[199:192] <= 0;                       // +018: cfg_interrupt_di
            rw[204:200] <= 5'b00111;                // +019: cfg_pciecap_interrupt_msgnum
            rw[205]     <= 0;                       //       cfg_interrupt_assert
            rw[206]     <= 0;                       //       cfg_interrupt
            rw[207]     <= 0;                       //       cfg_interrupt_stat
            // PCIe CTRL
            rw[209:208] <= 0;                       // +01A: cfg_pm_force_state
            rw[210]     <= 0;                       //       cfg_pm_force_state_en
            rw[211]     <= 0;                       //       cfg_pm_halt_aspm_l0s
            rw[212]     <= 0;                       //       cfg_pm_halt_aspm_l1
            rw[213]     <= 0;                       //       cfg_pm_send_pme_to
            rw[214]     <= 0;                       //       cfg_pm_wake
            rw[215]     <= 0;                       //       cfg_trn_pending
            rw[216]     <= 0;                       // +01B: cfg_turnoff_ok
            rw[217]     <= 1;                       //       rx_np_ok
            rw[218]     <= 1;                       //       rx_np_req
            rw[219]     <= 1;                       //       tx_cfg_gnt
            rw[223:220] <= 0;                       //       SLACK 
            // PCIe STATIC TLP TRANSMIT
            rw[224+:8]  <= 0;                       // +01C: TLP_STATIC TLP DWORD VALID [each-2bit: [0] = last, [1] = valid] [TLP DWORD 0-3]
            rw[232+:8]  <= 0;                       // +01D: TLP_STATIC TLP DWORD VALID [each-2bit: [0] = last, [1] = valid] [TLP DWORD 4-7]
            rw[240+:16] <= 0;                       // +01E: TLP_STATIC TLP TX SLEEP (ticks) [little-endian]
            rw[256+:384] <= 0;                      // +020: TLP_STATIC TLP [8*32-bit hdr+data]
            rw[640+:32] <= 0;                       // +050: TLP_STATIC TLP RETRANSMIT COUNT
            // PCIe STATUS register clear timer
            rw[672+:32] <= 62500;                   // +054: CFGSPACE_STATUS_CLEAR TIMER (ticks) [little-endian] [default = 1ms - 62.5k @ 62.5MHz]
            
        end
    endtask
    
    assign ctx.cfg_mgmt_rd_en               = rwi_cfg_mgmt_rd_en & ~ctx.cfg_mgmt_rd_wr_done;
    assign ctx.cfg_mgmt_wr_en               = rwi_cfg_mgmt_wr_en & ~ctx.cfg_mgmt_rd_wr_done;
    
    assign ctx.cfg_dsn                      = rw[127:64];
    assign ctx.cfg_mgmt_di                  = rw[159:128];
    assign ctx.cfg_mgmt_dwaddr              = rw[169:160];
    assign ctx.cfg_mgmt_wr_readonly         = rw[170];
    assign ctx.cfg_mgmt_wr_rw1c_as_rw       = rw[171];
    assign ctx.cfg_mgmt_byte_en             = rw[175:172];
    
    assign ctx.pl_directed_link_auton       = rw[176];
    assign ctx.pl_directed_link_change      = rw[178:177];
    assign ctx.pl_directed_link_speed       = rw[179];
    assign ctx.pl_directed_link_width       = rw[181:180];
    assign ctx.pl_upstream_prefer_deemph    = rw[182];
    assign ctx.pl_transmit_hot_rst          = rw[183];
    assign ctx.pl_downstream_deemph_source  = rw[184];
    
    assign ctx.cfg_interrupt_di             = rw[199:192];
    assign ctx.cfg_pciecap_interrupt_msgnum = rw[204:200];
    assign ctx.cfg_interrupt_assert         = rw[205];
    assign ctx.cfg_interrupt                = rw[206];
    assign ctx.cfg_interrupt_stat           = rw[207];

    assign ctx.cfg_pm_force_state           = rw[209:208];
    assign ctx.cfg_pm_force_state_en        = rw[210];
    assign ctx.cfg_pm_halt_aspm_l0s         = rw[211];
    assign ctx.cfg_pm_halt_aspm_l1          = rw[212];
    assign ctx.cfg_pm_send_pme_to           = rw[213];
    assign ctx.cfg_pm_wake                  = rw[214];
    assign ctx.cfg_trn_pending              = rw[215];
    assign ctx.cfg_turnoff_ok               = rw[216];
    assign ctx.rx_np_ok                     = rw[217];
    assign ctx.rx_np_req                    = rw[218];
    assign ctx.tx_cfg_gnt                   = rw[219];
    
    assign tlps_static.tdata[127:0]         = rwi_tlp_static_2nd ? {
        rw[(256+32*7+00)+:8], rw[(256+32*7+08)+:8], rw[(256+32*7+16)+:8], rw[(256+32*7+24)+:8],   // STATIC TLP DWORD7
        rw[(256+32*6+00)+:8], rw[(256+32*6+08)+:8], rw[(256+32*6+16)+:8], rw[(256+32*6+24)+:8],   // STATIC TLP DWORD6
        rw[(256+32*5+00)+:8], rw[(256+32*5+08)+:8], rw[(256+32*5+16)+:8], rw[(256+32*5+24)+:8],   // STATIC TLP DWORD5
        rw[(256+32*4+00)+:8], rw[(256+32*4+08)+:8], rw[(256+32*4+16)+:8], rw[(256+32*4+24)+:8]    // STATIC TLP DWORD4
    } : {
        rw[(256+32*3+00)+:8], rw[(256+32*3+08)+:8], rw[(256+32*3+16)+:8], rw[(256+32*3+24)+:8],   // STATIC TLP DWORD3
        rw[(256+32*2+00)+:8], rw[(256+32*2+08)+:8], rw[(256+32*2+16)+:8], rw[(256+32*2+24)+:8],   // STATIC TLP DWORD2
        rw[(256+32*1+00)+:8], rw[(256+32*1+08)+:8], rw[(256+32*1+16)+:8], rw[(256+32*1+24)+:8],   // STATIC TLP DWORD1
        rw[(256+32*0+00)+:8], rw[(256+32*0+08)+:8], rw[(256+32*0+16)+:8], rw[(256+32*0+24)+:8]    // STATIC TLP DWORD0
    };
    assign tlps_static.tkeepdw              = rwi_tlp_static_2nd ? { rw[224+2*7], rw[224+2*6], rw[224+2*5], rw[224+2*4] } : { rw[224+2*3], rw[224+2*2], rw[224+2*1], rw[224+2*0] };
    assign tlps_static.tlast                = rwi_tlp_static_2nd || rw[224+2*3+1] || rw[224+2*2+1] || rw[224+2*1+1] || rw[224+2*0+1];
    assign tlps_static.tuser[0]             = !rwi_tlp_static_2nd;
    assign tlps_static.tvalid               = rwi_tlp_static_valid && tlps_static.tkeepdw[0];
    assign tlps_static.has_data             = rwi_tlp_static_has_data;
        
    assign pcie_id                          = ro[79:64];
    
    // ------------------------------------------------------------------------
    // STATE MACHINE / LOGIC FOR READ/WRITE AND OTHER HOUSEKEEPING TASKS
    // ------------------------------------------------------------------------
    
    integer i_write, i_tlpstatic;
    wire [15:0] in_cmd_address_byte = in_dout[31:16];
    wire [17:0] in_cmd_address_bit  = {in_cmd_address_byte[14:0], 3'b000};
    wire [15:0] in_cmd_value        = {in_dout[48+:8], in_dout[56+:8]};
    wire [15:0] in_cmd_mask         = {in_dout[32+:8], in_dout[40+:8]};
    wire        f_rw                = in_cmd_address_byte[15]; 
    wire [15:0] in_cmd_data_in      = (in_cmd_address_bit < (f_rw ? $bits(rw) : $bits(ro))) ? (f_rw ? rw[in_cmd_address_bit+:16] : ro[in_cmd_address_bit+:16]) : 16'h0000;
    wire        in_cmd_read         = in_dout[12] & in_valid;
    wire        in_cmd_write        = in_dout[13] & in_cmd_address_byte[15] & in_valid;
    wire        pcie_cfg_rw_en      = rwi_cfg_mgmt_rd_en | rwi_cfg_mgmt_wr_en | rw[RWPOS_CFG_RD_EN] | rw[RWPOS_CFG_WR_EN];
    // in_rden = request data from incoming fifo. Only do this if there is space
    // in the output fifo and every 2nd clock cycle (in case a resulting write
    // starts an action that will last longer than a single clock there must be
    // time to react and stop reading incoming read/writes until processed).
    assign in_rden = tickcount64[1] & ~pcie_cfg_rx_almost_full & ( ~rw[RWPOS_CFG_WAIT_COMPLETE] | ~pcie_cfg_rw_en);
    
    initial pcileech_pcie_cfg_a7_initialvalues();
    
    always @ ( posedge clk_pcie )
        if ( rst )
            pcileech_pcie_cfg_a7_initialvalues();
        else
            begin         
                // READ config
                out_wren <= in_cmd_read;
                if ( in_cmd_read )
                    begin
                        out_data[31:16] <= in_cmd_address_byte;
                        out_data[15:0]  <= {in_cmd_data_in[7:0], in_cmd_data_in[15:8]};
                    end

                // WRITE config
                if ( in_cmd_write )
                    for ( i_write = 0; i_write < 16; i_write = i_write + 1 )
                        begin
                            if ( in_cmd_mask[i_write] )
                                rw[in_cmd_address_bit+i_write] <= in_cmd_value[i_write];
                        end

                // STATUS REGISTER CLEAR
                if ( (rw[RWPOS_CFG_CFGSPACE_STATUS_CL_EN] | rw[RWPOS_CFG_CFGSPACE_COMMAND_EN]) & ~in_cmd_read & ~in_cmd_write & ~rw[RWPOS_CFG_RD_EN] & ~rw[RWPOS_CFG_WR_EN] & ~rwi_cfg_mgmt_rd_en & ~rwi_cfg_mgmt_wr_en )
                    if ( rwi_count_cfgspace_status_cl < rw[672+:32] )
                        rwi_count_cfgspace_status_cl <= rwi_count_cfgspace_status_cl + 1;
                    else begin
                        rwi_count_cfgspace_status_cl <= 0;
						next_cfg_task = next_cfg_task + 1;
						if (next_cfg_task == 1)
						begin
                        rw[RWPOS_CFG_WR_EN] <= 1'b1;
                        rw[143:128] <= 16'h0406;                            // cfg_mgmt_di: command register [update to set individual command register bits]
                        rw[159:144] <= 16'hff00;                            // cfg_mgmt_di: status register [do not update]
                        rw[169:160] <= 1;                                   // cfg_mgmt_dwaddr
                        rw[170]     <= 0;                                   // cfg_mgmt_wr_readonly
                        rw[171]     <= 0;                                   // cfg_mgmt_wr_rw1c_as_rw
                        rw[172]     <= rw[RWPOS_CFG_CFGSPACE_COMMAND_EN];   // cfg_mgmt_byte_en: command register
                        rw[173]     <= rw[RWPOS_CFG_CFGSPACE_COMMAND_EN];   // cfg_mgmt_byte_en: command register
                        rw[174]     <= 0;                                   // cfg_mgmt_byte_en: status register
                        rw[175]     <= rw[RWPOS_CFG_CFGSPACE_STATUS_CL_EN]; // cfg_mgmt_byte_en: status register
                    end
					else if (next_cfg_task == 2)
					begin
					// Power State reset
						rw[RWPOS_CFG_WR_EN] <= 1'b1;
						rw[159:128] <= 32'h00000008; // cfg_mgmt_di
						rw[169:160] <= 10'h11; // cfg_mgmt_dwaddr ((11*4)=0x44)
						rw[170] <= 1; // cfg_mgmt_wr_readonly
						rw[171] <= 0; // cfg_mgmt_wr_rw1c_as_rw
						rw[172+:4] <= 4'b0001; // cfg_mgmt_byte_en
					end
					else if (next_cfg_task == 3)
					begin
					// Dev_cap
						rw[RWPOS_CFG_WR_EN] <= 1'b1;
						rw[159:128] <= 32'h00002830; // cfg_mgmt_di
						rw[169:160] <= 26; // cfg_mgmt_dwaddr ((26*4)=104=0x68)
						rw[170] <= 0; // cfg_mgmt_wr_readonly
						rw[171] <= 0; // cfg_mgmt_wr_rw1c_as_rw
						rw[172+:4] <= 4'b0011; // cfg_mgmt_byte_en
					end
					else if (next_cfg_task == 4 )
					begin
					// Link Status (doesnt work fully for some reason)
						rw[RWPOS_CFG_WR_EN] <= 1'b1;
						rw[159:128] <= 32'h10420040; // cfg_mgmt_di
						rw[169:160] <= 10'h1C; // cfg_mgmt_dwaddr ((1C*4)=0x70)
						rw[170] <= 1; // cfg_mgmt_wr_readonly
						rw[171] <= 0; // cfg_mgmt_wr_rw1c_as_rw
						rw[172+:4] <= 4'b1111; // cfg_mgmt_byte_en
					end
					else if (next_cfg_task == 5 )
					begin
					// Message Data
						rw[RWPOS_CFG_WR_EN] <= 1'b1;
						rw[159:128] <= 32'h000049B2; // cfg_mgmt_di
						rw[169:160] <= 10'h15; // cfg_mgmt_dwaddr ((15*4)=0x60=0x??)
						rw[170] <= 0; // cfg_mgmt_wr_readonly
						rw[171] <= 0; // cfg_mgmt_wr_rw1c_as_rw
						rw[172+:4] <= 4'b0011; // cfg_mgmt_byte_en
					end
					else if (next_cfg_task == 6)
					begin
					// Interrupt Line
						rw[RWPOS_CFG_WR_EN] <= 1'b1;
						rw[159:128] <= 32'h00000000; // cfg_mgmt_di
						rw[169:160] <= 10'hF; // cfg_mgmt_dwaddr ((1C*4)=0x70)
						rw[170] <= 0; // cfg_mgmt_wr_readonly
						rw[171] <= 0; // cfg_mgmt_wr_rw1c_as_rw
						rw[172+:4] <= 4'b0001; // cfg_mgmt_byte_en
					end
					else if (next_cfg_task == 7 )
					begin
					// Link Status (doesnt work fully for some reason) ! Attempt 2
						rw[RWPOS_CFG_WR_EN] <= 1'b1;
						rw[159:128] <= 32'h10420040; // cfg_mgmt_di
						rw[169:160] <= 10'h1C; // cfg_mgmt_dwaddr ((1C*4)=0x70)
						rw[170] <= 0; // cfg_mgmt_wr_readonly ?? maybe this would work?
						rw[171] <= 1; // cfg_mgmt_wr_rw1c_as_rw ?? this????
						rw[172+:4] <= 4'b1111; // cfg_mgmt_byte_en
					end
					else if (next_cfg_task == 8 )
					begin
					// MSI (Message interrupts) -> enabled.
						rw[RWPOS_CFG_WR_EN] <= 1'b1;
						rw[159:128] <= 32'h00816005; // cfg_mgmt_di
						rw[169:160] <= 10'h12; // cfg_mgmt_dwaddr ((12*4)=0x48)
						rw[170] <= 0; // cfg_mgmt_wr_readonly
						rw[171] <= 0; // cfg_mgmt_wr_rw1c_as_rw
						rw[172+:4] <= 4'b0100; // cfg_mgmt_byte_en
					end
					else if (next_cfg_task == 9 )
					begin
					// Test_cap not work
						rw[RWPOS_CFG_WR_EN] <= 1'b1;
						rw[159:128] <= 32'hFEE20F0C; // cfg_mgmt_di
						rw[169:160] <= 10'h19; // cfg_mgmt_dwaddr ((19*4)=0x76)
						rw[170] <= 0; // cfg_mgmt_wr_readonly
						rw[171] <= 0; // cfg_mgmt_wr_rw1c_as_rw
						rw[172+:4] <= 4'b0100; // cfg_mgmt_byte_en
					end
					else if (next_cfg_task == 10 )
					begin
					// 0x64
						rw[RWPOS_CFG_WR_EN] <= 1'b1;
						rw[159:128] <= 32'h07E88E02; // cfg_mgmt_di
						rw[169:160] <= 10'h16; // cfg_mgmt_dwaddr ((16*4)=0x64)
						rw[170] <= 0; // cfg_mgmt_wr_readonly
						rw[171] <= 0; // cfg_mgmt_wr_rw1c_as_rw
						rw[172+:4] <= 4'b0100; // cfg_mgmt_byte_en
					end
					else
					begin
						next_cfg_task = 0;
						rwi_count_cfgspace_status_cl <= 0;
					end
					end
                
                if ((base_address_register_reg == 32'h00000000) | (base_address_register_reg == 32'hFFC00000))
                    if ( ~in_cmd_read & ~in_cmd_write & ~rw[RWPOS_CFG_RD_EN] & ~rw[RWPOS_CFG_WR_EN] & ~rwi_cfg_mgmt_rd_en & ~rwi_cfg_mgmt_wr_en )
                        begin
                            rw[RWPOS_CFG_RD_EN] <= 1'b1;
                            rw[169:160] <= 4;                                   // cfg_mgmt_dwaddr
                            rw[172]     <= 0;                                   // cfg_mgmt_byte_en
                            rw[173]     <= 0;                                   // cfg_mgmt_byte_en
                            rw[174]     <= 0;                                   // cfg_mgmt_byte_en
                            rw[175]     <= 0;                                   // cfg_mgmt_byte_en
                        end
                
                // CONFIG SPACE READ/WRITE                        
                if ( ctx.cfg_mgmt_rd_wr_done )
                    begin
                         // if BAR0 was requested, lets save it.
                         if ((base_address_register_reg == 32'h00000000) | (base_address_register_reg == 32'hFFE00000))
                            if ((ctx.cfg_mgmt_dwaddr == 8'h04) & rwi_cfg_mgmt_rd_en)
                                begin
                                    base_address_register_reg <= ctx.cfg_mgmt_do;
                                end
                        
                        rwi_cfg_mgmt_rd_en  <= 1'b0;
                        rwi_cfg_mgmt_wr_en  <= 1'b0;
                        rwi_cfgrd_valid     <= 1'b1;
                        rwi_cfgrd_addr      <= ctx.cfg_mgmt_dwaddr;
                        rwi_cfgrd_data      <= ctx.cfg_mgmt_do;
                        rwi_cfgrd_byte_en   <= ctx.cfg_mgmt_byte_en;
                    end
                else if ( rw[RWPOS_CFG_RD_EN] )
                    begin
                        rw[RWPOS_CFG_RD_EN] <= 1'b0;
                        rwi_cfg_mgmt_rd_en  <= 1'b1;
                        rwi_cfgrd_valid     <= 1'b0;
                    end
                else if ( rw[RWPOS_CFG_WR_EN] )
                    begin
                        rw[RWPOS_CFG_WR_EN] <= 1'b0;
                        rwi_cfg_mgmt_wr_en  <= 1'b1;
                        rwi_cfgrd_valid     <= 1'b0;
                    end
                    
                // STATIC_TLP TRANSMIT
                if ( (rwi_tlp_static_valid && rwi_tlp_static_2nd) || ~rw[RWPOS_CFG_STATIC_TLP_TX_EN] ) begin    // STATE (3)
                    rwi_tlp_static_valid    <= 1'b0;
                    rwi_tlp_static_has_data <= 1'b0;
                end
                else if ( rwi_tlp_static_has_data && tlps_static.tready && rwi_tlp_static_2nd ) begin  // STATE (1)
                     rwi_tlp_static_valid   <= 1'b1;
                     rwi_tlp_static_2nd     <= 1'b0;
                end
                else if ( rwi_tlp_static_has_data && tlps_static.tready && !rwi_tlp_static_2nd ) begin // STATE (2)
                     rwi_tlp_static_valid   <= 1'b1;
                     rwi_tlp_static_2nd     <= 1'b1;
                end
                else if ( ((tickcount64[0+:16] & rw[240+:16]) == rw[240+:16]) & (rw[640+:32] > 0) & rw[224+2*0] ) begin   // IDLE STATE (0)
                    rwi_tlp_static_has_data <= 1'b1;
                    rwi_tlp_static_2nd      <= 1'b1;
                    rw[640+:32] <= rw[640+:32] - 1;     // count - 1
                    if ( rw[640+:32] == 32'h00000001 )
                        rw[RWPOS_CFG_STATIC_TLP_TX_EN] <= 1'b0;
                end
                
            end
    
endmodule
