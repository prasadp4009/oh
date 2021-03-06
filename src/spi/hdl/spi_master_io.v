//#############################################################################
//# Purpose: SPI slave IO and statemachine                                    #
//#############################################################################
//# Author:   Andreas Olofsson                                                #
//# License:  MIT (see below)                                                 # 
//#############################################################################

module spi_master_io(/*AUTOARG*/
   // Outputs
   spi_state, fifo_read, rx_data, rx_access, sclk, mosi, ss,
   // Inputs
   clk, nreset, spi_en, cpol, cpha, lsbfirst, clkdiv_reg, cmd_reg,
   emode, fifo_dout, fifo_empty, miso
   );

   //#################################
   //# INTERFACE
   //#################################

   //parameters
   parameter  REGS  = 16;         // total regs  (16/32/64) 
   parameter  AW    = 32;         // address width
   localparam PW    = (2*AW+40);  // packet width
   
   //clk, reset, cfg
   input 	   clk;        // core clock
   input 	   nreset;     // async active low reset
   
   //cfg
   input 	   spi_en;     // spi enable
   input 	   cpol;       // cpol
   input 	   cpha;       // cpha
   input 	   lsbfirst;   // send lsbfirst   
   input [7:0] 	   clkdiv_reg; // baudrate	 
   input [7:0] 	   cmd_reg; 	   
   input 	   emode;       
   output [1:0]    spi_state;  // current spi tx state
     
   //data to transmit
   input [7:0] 	   fifo_dout;  // data payload
   input 	   fifo_empty; // 
   output 	   fifo_read;  // read new byte
   
   //receive data (for sregs)
   output [63:0]   rx_data;    // rx data
   output 	   rx_access;  // transfer done
   
   //IO interface
   output 	   sclk;       // spi clock
   output 	   mosi;       // slave input
   output 	   ss;         // slave select
   input 	   miso;       // slave output

   reg [1:0] 	   spi_state;
   reg 		   fifo_empty_reg;
   reg 		   load_byte;   

   wire [7:0] 	   data_out;
   wire [15:0] 	   clkphase0;
   
   /*AUTOWIRE*/
   // Beginning of automatic wires (for undeclared instantiated-module outputs)
   wire			clkfall1;		// From oh_clockdiv of oh_clockdiv.v
   wire			clkout1;		// From oh_clockdiv of oh_clockdiv.v
   wire			clkrise1;		// From oh_clockdiv of oh_clockdiv.v
   // End of automatics
   
   //#################################
   //# CLOCK GENERATOR
   //#################################
   assign clkphase0[7:0]  = 'b0;
   assign clkphase0[15:8] = (clkdiv_reg[7:0]+1'b1)>>1;
   
   oh_clockdiv #(.DW(8))
   oh_clockdiv (.clkdiv		(clkdiv_reg[7:0]),
		.clken		(1'b1),	
		.clkrise0	(period_match),
		.clkfall0	(phase_match),	
		.clkphase1	(16'b0),
		.clkout0	(clkout),
		/*AUTOINST*/
		// Outputs
		.clkout1		(clkout1),
		.clkrise1		(clkrise1),
		.clkfall1		(clkfall1),
		// Inputs
		.clk			(clk),
		.nreset			(nreset),
		.clkphase0		(clkphase0[15:0]));
    
   //#################################
   //# STATE MACHINE
   //#################################

`define SPI_IDLE    2'b00  // set ss to 1
`define SPI_SETUP   2'b01  // setup time
`define SPI_DATA    2'b10  // send data
`define SPI_HOLD    2'b11  // hold time

   always @ (posedge clk or negedge nreset)
     if(!nreset)
       spi_state[1:0] <=  `SPI_IDLE;
   else
     case (spi_state[1:0])
       `SPI_IDLE : 
	 spi_state[1:0] <= fifo_read ? `SPI_SETUP : `SPI_IDLE;
       `SPI_SETUP :
	 spi_state[1:0] <= period_match ? `SPI_DATA : `SPI_SETUP;       
       `SPI_DATA : 
	 spi_state[1:0] <= data_done ? `SPI_HOLD : `SPI_DATA;
       `SPI_HOLD : 
	 spi_state[1:0] <= period_match ? `SPI_IDLE : `SPI_HOLD;
     endcase // case (spi_state[1:0])
   
   //read fifo on phase match (due to one cycle pipeline latency
   assign fifo_read = ~fifo_empty & ~spi_wait & period_match;

   //data done whne
   assign data_done = fifo_empty & ~spi_wait & period_match;

   //shift on every clock cycle while in datamode
   assign shift     = period_match & (spi_state[1:0]==`SPI_DATA);
   
   //load is the result of the fifo_read
   always @ (posedge clk)
     load_byte <= fifo_read;
   
   //#################################
   //# CHIP SELECT
   //#################################
   
   assign ss = (spi_state[1:0]==`SPI_IDLE);

   //#################################
   //# DRIVE OUTPUT CLOCK
   //#################################
   
   assign sclk = clkout & (spi_state[1:0]==`SPI_DATA);

   //#################################
   //# TX SHIFT REGISTER
   //#################################
   
   assign data_out[7:0] = (emode & spi_state[1:0]==`SPI_IDLE) ? cmd_reg[7:0] : 
			                                        fifo_dout[7:0];
   
   oh_par2ser  #(.PW(8),
		 .SW(1))
   par2ser (// Outputs
	    .dout	(mosi),           // serial output
	    .access_out	(),
	    .wait_out	(spi_wait),
	    // Inputs
	    .clk	(clk),
	    .nreset	(nreset),         // async active low reset
	    .din	(data_out[7:0] ), // 8 bit data from fifo
	    .shift	(shift),          // shift on neg edge
	    .datasize	(8'd7),           // 8 bits
	    .load	(load_byte),      // load data from fifo
	    .lsbfirst	(lsbfirst),       // serializer direction
	    .fill	(1'b0),           // fill with slave data
	    .wait_in	(1'b0)            // no wait
	    );

   //#################################
   //# RX SHIFT REGISTER
   //#################################

   //generate access pulse at rise of ss
   oh_rise2pulse 
     pulse (.out (rx_access),
	    .clk (clk),
	    .in	 (ss));
   
   oh_ser2par #(.PW(64),
		.SW(1))
   ser2par (//output
	    .dout	(rx_data[63:0]),  // parallel data out
	    //inputs
	    .din	(miso),           // serial data in
	    .clk	(clk),            // shift clk
	    .lsbfirst	(lsbfirst),       // shift direction
	    .shift	(shift));         // shift data
         
endmodule // spi_slave_io

// Local Variables:
// verilog-library-directories:("." "../../common/hdl" "../../emesh/hdl") 
// End:

///////////////////////////////////////////////////////////////////////////////
// The MIT License (MIT)                                                     //
//                                                                           //
// Copyright (c) 2015-2016, Adapteva, Inc.                                   //
//                                                                           //
// Permission is hereby granted, free of charge, to any person obtaining a   //
// copy of this software and associated documentation files (the "Software") //
// to deal in the Software without restriction, including without limitation // 
// the rights to use, copy, modify, merge, publish, distribute, sublicense,  //
// and/or sell copies of the Software, and to permit persons to whom the     //
// Software is furnished to do so, subject to the following conditions:      //
//                                                                           //
// The above copyright notice and this permission notice shall be included   // 
// in all copies or substantial portions of the Software.                    //
//                                                                           //
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS   //
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF                //
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.    //
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY      //
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT //
// OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR  //
// THE USE OR OTHER DEALINGS IN THE SOFTWARE.                                //
//                                                                           //  
///////////////////////////////////////////////////////////////////////////////


