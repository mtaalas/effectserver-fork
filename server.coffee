CSON = require "cson"
dgram = require "dgram"
fs = require "fs"
util = require "util"
EventEmitter = require "events"

process.on 'uncaughtException', (err) ->
  console.log 'Caught exception', err

{EffectManager} = require "./lib/effectmanager"
{packetParse} = require "./lib/packetparser"

{webserver, websocket} = require "./web/webserver"
udpserver = dgram.createSocket("udp4")


onConfigRead = (error, config) ->
  if error
    console.error 'failed to read configuration file:', error
    throw error
  webserver.config = config

  manager = new EffectManager config.hosts, config.mapping
  manager.build()

  webserver.get "/config.json", (req, res) ->
    res.json manager.toJSON()

  if process.env.TAG
    firewall =
      allowOnly:
        tag: process.env.TAG

    setTimeout ->
      console.log "FIREWALL", firewall
    , 1000

  websocket.sockets.on "connection", (socket) ->
    socket.on "message", (msg) ->
      buf = Buffer.from msg
      address = socket.handshake.address.address
      try
        console.log "socket.io packet", buf
        cmds = packetParse buf
      catch e
        # TODO: catch only parse errors
        websocket.sockets.volatile.emit "parseError",
          error: e.message
          address: address

        # Failed to parse the packet. We cannot continue from here at all.
        return
      handleCmds cmds, address

  udpserver.on "message", (packet, rinfo) ->
    try
      console.log "UDP packet", packet
      cmds = packetParse packet
    catch e
      # TODO: catch only parse errors
      websocket.sockets.volatile.emit "parseError",
        error: e.message
        address: rinfo.address

      # Failed to parse the packet. We cannot continue from here at all.
      return
    handleCmds cmds, rinfo.address

  handleCmds = (cmds, address) ->
    results =
      # Packet starts as anonymous always
      tag: "anonymous"
      address: address
      cmds: []

    for cmd in cmds

      # First fragment might tag this packet
      if cmd.tag
        results.tag = cmd.tag.substring(0, 15)
        continue # to next fragment

      if firewall?
        if results.tag isnt firewall.allowOnly.tag
          console.log "Bad tag '#{ results.tag }' we need '#{ firewall.allowOnly.tag }'"
          continue

      if error = manager.route cmd
        cmd.error = error

      results.cmds.push cmd


    manager.commitAll()

    # No debug when firewall is on
    if not firewall?
      websocket.sockets.volatile.emit "cmds", results

  udpserver.on "listening", ->
    console.log "Now listening on UDP port #{ config.servers.udpPort }"
  udpserver.bind config.servers.udpPort

  webserver.listen config.servers.httpPort, ->
    console.log "Now listening on HTTP port #{ config.servers.httpPort }"

try
  CSON.parseFile __dirname + '/config.cson', { format: 'cson' }, onConfigRead
catch e
  console.log 'Unable to read config.cson!', e
  process.exit 1


