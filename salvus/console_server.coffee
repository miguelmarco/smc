#################################################################
#
# console_server -- a node.js tty console server
#
#   * the server, which runs as a command-line daemon (or can
#     be used as a library)
#
#   * the client, which e.g. gets imported by hub and used
#     for communication between hub and the server daemon.
#
# For local debugging, run this way, since it gives better stack traces.
#
#         make_coffee && echo "require('console_server').start_server()" | coffee
#
#################################################################

async          = require 'async'
fs             = require 'fs'
net            = require 'net'
child_process  = require 'child_process'
message        = require 'message'
misc_node      = require 'misc_node'
winston        = require 'winston'

{to_json, from_json, defaults, required}   = require 'misc'


makedirs = (path, uid, gid, cb) ->
    # TODO: this should split the path and make sure everything is
    # made along the way like in Python, but I'm going to wait on
    # implementing, since with internet maybe find that already in a
    # library.
    async.series([
        (c) -> fs.exists path, (exists) ->
            if exists # done
                cb(); c(true)
            else
                c()
        (c) -> fs.mkdir path, (err) ->
            if err
                cb(err); c(true)
            else
                c()
        (c) ->
            if not uid? or not gid?
                cb(); c()
            else
                fs.chown path, uid, gid, (err) ->
                    if err
                        cb(err); c(true)
                    else
                        cb(); c()
    ])

start_session = (socket, mesg) ->
    if not mesg.limits? or not mesg.limits.walltime?
        socket.write_mesg('json', message.error(id:mesg.id, error:"mesg.limits.walltime *must* be defined"))
        return

    winston.info "start_session #{to_json(mesg)}"
    opts = defaults mesg.params,
        home    : required
        rows    : 24
        cols    : 80
        command : undefined
        args    : ['--norc']
        ps1     : '\\w\\$ '
        path    : process.env.PATH
        cwd     : undefined          # starting PATH -- default is computed below

    opts.cputime  = mesg.limits.cputime
    opts.vmem     = mesg.limits.vmem
    opts.numfiles = mesg.limits.numfiles

    if process.getuid() == 0  # root
        winston.debug "running as root, so forking with reduced privileges"
        opts.uid = Math.floor(2000 + Math.random()*1000)  # TODO: just for testing; hub/database will *have* to assign this soon
        opts.gid = opts.uid
        opts.home = "/tmp/salvus/#{opts.home}"
    else
        opts.home = process.env.HOME
        opts.cwd = opts.home

    if not opts.cwd?
        opts.cwd = opts.home

    winston.debug "start_session opts = #{to_json(opts)}"

    # If opts.home does not exist, create it and set the right
    # permissions before dropping privileges:
    makedirs opts.home, opts.uid, opts.gid, (err) ->
        if err
            winston.error "ERROR: #{err}" # no way to report error further... yet
        else
            # Fork of a child process that drops privileges and does all further work to handle a connection.
            child = child_process.fork(__dirname + '/console_server_child.js', [])
            # Send the pid of the child back
            socket.write_mesg('json', message.session_description({pid:child.pid, limits:mesg.limits}))
            # Disable use of the socket for sending/receiving messages.
            misc_node.disable_mesg(socket)
            # Give the socket to the child, along with the options
            child.send(opts, socket)
            # No session lives forever -- set a timer to kill the spawned child
            setTimeout((() -> child.kill('SIGKILL')), mesg.limits.walltime*1000)
            winston.info "PARENT: forked off child to handle it"

handle_client = (socket, mesg) ->
    try
        switch mesg.event
            when 'start_session'
                start_session(socket, mesg)
            when 'send_signal'
                switch mesg.signal
                    when 2
                        signal = 'SIGINT'
                    when 3
                        signal = 'SIGQUIT'
                    when 9
                        signal = 'SIGKILL'
                    else
                        throw("only signals 2 (SIGINT), 3 (SIGQUIT), and 9 (SIGKILL) are supported")
                process.kill(mesg.pid, signal)
                if mesg.id?
                    socket.write_mesg('json', message.signal_sent(id:mesg.id))
            else
                if mesg.id?
                    err = message.error(id:mesg.id, error:"Console server received an invalid mesg type '#{mesg.event}'")
                socket.write_mesg('json', err)
    catch e
        winston.error "ERROR: '#{e}' handling message '#{to_json(mesg)}'"

server = net.createServer (socket) ->
    winston.debug "PARENT: received connection"
    # Receive a single message:
    misc_node.enable_mesg(socket)
    socket.on 'mesg', (type, mesg) ->
        winston.debug "received control mesg #{mesg}"
        handle_client(socket, mesg)

# Start listening for connections on the socket.
exports.start_server = start_server = () ->
    server.listen program.port, program.host, () -> winston.info "listening on port #{program.port}"

# daemonize it

program = require('commander')
daemon  = require("start-stop-daemon")

program.usage('[start/stop/restart/status] [options]')
    .option('-p, --port <n>', 'port to listen on (default: 6001)', parseInt, 6001)
    .option('--pidfile [string]', 'store pid in this file (default: "data/pids/console_server.pid")', String, "data/pids/console_server.pid")
    .option('--logfile [string]', 'write log to this file (default: "data/logs/console_server.log")', String, "data/logs/console_server.log")
    .option('--host [string]', 'bind to only this host (default: "127.0.0.1")', String, "127.0.0.1")   # important for security reasons to prevent user binding more specific host attack
    .parse(process.argv)

if program._name == 'console_server.js'
    # run as a server/daemon (otherwise, is being imported as a library)
    process.addListener "uncaughtException", (err) ->
        winston.error "Uncaught exception: " + err
        if console? and console.trace?
            console.trace()
    daemon({pidFile:program.pidfile, outFile:program.logfile, errFile:program.logfile}, start_server)


