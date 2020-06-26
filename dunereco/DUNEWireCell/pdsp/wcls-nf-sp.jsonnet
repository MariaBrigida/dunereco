// This is a main entry point to configure a WC/LS job that applies
// noise filtering and signal processing to existing RawDigits.  The
// FHiCL is expected to provide the following parameters as attributes
// in the "params" structure.
//
// epoch: the hardware noise fix expoch: "before", "after", "dynamic" or "perfect"
// reality: whether we are running on "data" or "sim"ulation.
// raw_input_label: the art::Event inputTag for the input RawDigit
//
// see the .fcl of the same name for an example
//
// Manual testing, eg:
//
// jsonnet -V reality=data -V epoch=dynamic -V raw_input_label=daq \\
//         -V signal_output_form=sparse \\
//         -J cfg cfg/pgrapher/experiment/uboone/wcls-nf-sp.jsonnet
//
// jsonnet -V reality=sim -V epoch=perfect -V raw_input_label=daq \\
//         -V signal_output_form=sparse \\
//         -J cfg cfg/pgrapher/experiment/uboone/wcls-nf-sp.jsonnet


local epoch = std.extVar('epoch');  // eg "dynamic", "after", "before", "perfect"
local reality = std.extVar('reality');
local sigoutform = std.extVar('signal_output_form');  // eg "sparse" or "dense"


local wc = import 'wirecell.jsonnet';
local g = import 'pgraph.jsonnet';

local raw_input_label = std.extVar('raw_input_label');  // eg "daq"


local data_params = import 'params.jsonnet';
local simu_params = import 'simparams.jsonnet';
local params = if reality == 'data' then data_params else simu_params;


local tools_maker = import 'pgrapher/common/tools.jsonnet';
local tools = tools_maker(params);

local wcls_maker = import 'pgrapher/ui/wcls/nodes.jsonnet';
local wcls = wcls_maker(params, tools);

//local nf_maker = import "pgrapher/experiment/pdsp/nf.jsonnet";
//local chndb_maker = import "pgrapher/experiment/pdsp/chndb.jsonnet";

local sp_maker = import 'pgrapher/experiment/pdsp/sp.jsonnet';

//local chndbm = chndb_maker(params, tools);
//local chndb = if epoch == "dynamic" then chndbm.wcls_multi(name="") else chndbm.wct(epoch);


// Collect the WC/LS input converters for use below.  Make sure the
// "name" argument matches what is used in the FHiCL that loads this
// file.  In particular if there is no ":" in the inputer then name
// must be the emtpy string.
local wcls_input = {
  adc_digits: g.pnode({
    type: 'wclsRawFrameSource',
    name: '',
    data: {
      art_tag: raw_input_label,
      frame_tags: ['orig'],  // this is a WCT designator
      // nticks: params.daq.nticks,
    },
  }, nin=0, nout=1),

};

// Collect all the wc/ls output converters for use below.  Note the
// "name" MUST match what is used in theh "outputers" parameter in the
// FHiCL that loads this file.
local mega_anode = {
  type: 'MegaAnodePlane',
  name: 'meganodes',
  data: {
    anodes_tn: [wc.tn(anode) for anode in tools.anodes],
  },
};
local wcls_output = {
  // The noise filtered "ADC" values.  These are truncated for
  // art::Event but left as floats for the WCT SP.  Note, the tag
  // "raw" is somewhat historical as the output is not equivalent to
  // "raw data".
  nf_digits: g.pnode({
    type: 'wclsFrameSaver',
    name: 'nfsaver',
    data: {
      // anode: wc.tn(tools.anode),
      anode: wc.tn(mega_anode),
      digitize: true,  // true means save as RawDigit, else recob::Wire
      frame_tags: ['raw'],
      // nticks: params.daq.nticks,
      chanmaskmaps: ['bad'],
    },
  }, nin=1, nout=1, uses=[mega_anode]),


  // The output of signal processing.  Note, there are two signal
  // sets each created with its own filter.  The "gauss" one is best
  // for charge reconstruction, the "wiener" is best for S/N
  // separation.  Both are used in downstream WC code.
  sp_signals: g.pnode({
    type: 'wclsFrameSaver',
    name: 'spsaver',
    data: {
      // anode: wc.tn(tools.anode),
      anode: wc.tn(mega_anode),
      digitize: false,  // true means save as RawDigit, else recob::Wire
      frame_tags: ['gauss', 'wiener'],
      frame_scale: [0.005, 0.005],
      // nticks: params.daq.nticks,
      chanmaskmaps: [],
      nticks: -1,
    },
  }, nin=1, nout=1, uses=[mega_anode]),
};

// local perfect = import 'chndb-perfect.jsonnet';
local base = import 'chndb-base.jsonnet';
local chndb = [{
  type: 'OmniChannelNoiseDB',
  name: 'ocndbperfect%d' % n,
  // data: perfect(params, tools.anodes[n], tools.field, n),
  data: base(params, tools.anodes[n], tools.field, n),
  uses: [tools.anodes[n], tools.field],  // pnode extension
} for n in std.range(0, std.length(tools.anodes) - 1)];

local nf_maker = import 'pgrapher/experiment/pdsp/nf.jsonnet';
local nf_pipes = [nf_maker(params, tools.anodes[n], chndb[n], n, name='nf%d' % n) for n in std.range(0, std.length(tools.anodes) - 1)];

local sp = sp_maker(params, tools, { sparse: sigoutform == 'sparse' });
local sp_pipes = [sp.make_sigproc(a) for a in tools.anodes];

local chsel_pipes = [
  g.pnode({
    type: 'ChannelSelector',
    name: 'chsel%d' % n,
    data: {
      channels: std.range(2560 * n, 2560 * (n + 1) - 1),
      //channels: if n==0 then std.range(2560*n,2560*(n+1)-1) else [],
      //tags: ['orig%d' % n], // traces tag
    },
  }, nin=1, nout=1)
  for n in std.range(0, std.length(tools.anodes) - 1)
];

local magoutput = 'protodune-data-check.root';
local magnify = import 'pgrapher/experiment/pdsp/magnify-sinks.jsonnet';
local sinks = magnify(tools, magoutput);

local nfsp_pipes = [
  g.pipeline([
               chsel_pipes[n],
               // sinks.orig_pipe[n],

               // nf_pipes[n],
               // sinks.raw_pipe[n],

               sp_pipes[n],
               // sinks.decon_pipe[n],
               // sinks.threshold_pipe[n],
               // sinks.debug_pipe[n], // use_roi_debug_mode=true in sp.jsonnet
             ],
             'nfsp_pipe_%d' % n)
  for n in std.range(0, std.length(tools.anodes) - 1)
];

//local f = import 'pgrapher/common/funcs.jsonnet';
local f = import 'pgrapher/experiment/pdsp/funcs.jsonnet';
//local outtags = ['gauss%d' % n for n in std.range(0, std.length(tools.anodes) - 1)];
//local fanpipe = f.fanpipe('FrameFanout', nfsp_pipes, 'FrameFanin', 'sn_mag_nf', outtags);
local fanpipe = f.fanpipe('FrameFanout', nfsp_pipes, 'FrameFanin', 'sn_mag_nf');

local retagger = g.pnode({
  type: 'Retagger',
  data: {
    // Note: retagger keeps tag_rules an array to be like frame fanin/fanout.
    tag_rules: [{
      // Retagger also handles "frame" and "trace" like fanin/fanout
      // merge separately all traces like gaussN to gauss.
      frame: {
        '.*': 'retagger',
      },
      merge: {
        'gauss\\d': 'gauss',
        'wiener\\d': 'wiener',
      },
    }],
  },
}, nin=1, nout=1);

local sink = g.pnode({ type: 'DumpFrames' }, nin=1, nout=0);


// local graph = g.pipeline([wcls_input.adc_digits, rootfile_creation_frames, fanpipe, retagger, wcls_output.sp_signals, sink]);
local graph = g.pipeline([wcls_input.adc_digits, fanpipe, retagger, wcls_output.sp_signals, sink]);

local app = {
  type: 'Pgrapher',
  data: {
    edges: g.edges(graph),
  },
};

// Finally, the configuration sequence
g.uses(graph) + [app]
