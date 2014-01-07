cidrMatch = require 'cidr_match'
express = require 'express'
http = require 'http'
moment = require 'moment'
sanitize = require('validator').sanitize
sockjs = require 'sockjs'

app = express()
app.enable 'trust proxy'
app.use express.logger()
app.use express.compress()
app.use "/static", express.static("#{ __dirname }/static")

app.set 'ipWhitelist', [
	'128.135.0.0/16',
	'205.208.0.0/17',
	'165.68.0.0/16',
	'64.107.48.0/23'
]
app.set 'overridePassword', 'worldoftanks'

app.get '/', (req, res) ->
	if req.query.override == app.get('overridePassword') 
		res.sendfile "#{ __dirname }/index.html"
		return
	for ipr in app.get('ipWhitelist')
		if cidrMatch.cidr_match req.ip, ipr
			res.sendfile "#{ __dirname }/index.html"	
			return
	res.sendfile "#{ __dirname }/bad_ip.html"
	

chatServer = sockjs.createServer {
	prefix: '/server',
	sockjs_url: 'http://cdn.sockjs.org/sockjs-0.3.min.js',
	log: (severity, message) ->
		if severity == 'error'
			console.log message
}

httpServer = http.createServer app
chatServer.installHandlers httpServer
httpServer.listen 10001, '127.0.0.1'

lobby = []

lobbyRotate = ->
	if lobby.length > 0
		user = lobby.shift()
		if lobby.length > 0
			user.writeJSON {type: 'refresh'}
		else
			lobby.push user
	setTimeout lobbyRotate, 2500
lobbyRotate()

dtNow = ->
	return "[#{ moment().format('MM/DD/YYYY hh:mm A') }]"

chatServer.on 'connection', (conn) ->
	console.log "#{ conn.id } connected"

	conn.writeJSON = (data) ->
		conn.write JSON.stringify(data)
	conn.on 'data', (message) ->
		data = JSON.parse(message)
		if data.type?
			conn.emit data.type, data
	conn.on 'initialize', ->
		#console.log "Initializing connection for #{ conn.id }"
		lobby = lobby.filter (v) ->
			return v.id != conn.id
		if lobby.length > 0
			partner = lobby.shift()
			conn.partner = partner
			partner.partner = conn
			console.log "Partnered #{ conn.id } with #{ partner.id }"
			conn.writeJSON {type: 'sdp', sdp: partner.sdpOffer}
		else
			#console.log "No partners available for #{ conn.id } - adding to lobby and requesting SDP offer"
			conn.writeJSON {type: 'requestOffer'}

	conn.on 'offer', (data) ->
		conn.sdpOffer = data.sdp
		lobby.push(conn)
		#console.log "Received SDP offer from #{ conn.id }"
		#console.log "Conns in lobby: #{ lobby.length }"

	forwardHandler = (data) ->
		if conn.partner?
			conn.partner.writeJSON data

	conn.on 'sdp', (data) ->
		forwardHandler data


	conn.on 'candidate', (data) ->
		forwardHandler data

	conn.on 'chat', (data) ->
		if data.message? and conn.partner?
			data.message = sanitize(data.message).entityEncode()
			conn.writeJSON data
			forwardHandler data
			console.log "#{ dtNow() } #{ data.message }"

	leaveHandler = ->
		console.log "#{ conn.id } disconnected"
		lobby = lobby.filter (v) ->
			return v.id != conn.id
		if conn.partner?
			conn.partner.writeJSON {type: 'remoteLeft'}
			conn.partner.partner = null

	conn.on 'leave', ->
		leaveHandler() 

	conn.on 'close', (data) ->
		leaveHandler()
