//============================================================================
//  Debug: 64 bit In-System Sources and Probes instance, readable over JTAG
//  (tools/ns10trace.py probe <instance id>).
//============================================================================

module ns10_probe #(parameter ID = "PRB0")
(
	input  [63:0] probe,
	output  [0:0] source
);

`ifdef NS10_DEBUG
altsource_probe #(.sld_auto_instance_index("YES"), .instance_id(ID), .probe_width(64), .source_width(1),
                  .source_initial_value("0"), .enable_metastability("NO")) sp
(
	.probe(probe), .source(source)
);
`else
assign source = 1'b0;   // release: no JTAG probe, the probed debug counters are removed by synthesis
`endif

endmodule
