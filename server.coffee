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
	'127.0.0.0/8',
	'128.135.0.0/16',
	'205.208.0.0/17',
	'165.68.0.0/16',
	'64.107.48.0/23'
]

app.get '/', (req, res) ->
	res.sendfile "#{ __dirname }/index.html"
	

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

dtNow = ->
	return "[#{ moment().format('MM/DD/YYYY hh:mm:ss A') }]"

lobby = []
lobbyRefresh = ->
	if lobby.length >= 2
		c = lobby.shift()
		c.writeJSON {type: 'refresh'}
		console.log "Sent refresh signal to #{ c.id }"
setInterval lobbyRefresh, 1000

chatServer.on 'connection', (conn) ->
	conn.writeJSON = (data) ->
		conn.write JSON.stringify(data)

	if app.get('trust proxy')
		if conn.headers['x-forwarded-for']?
			conn.ip = conn.headers['x-forwarded-for'].split(', ')[0]
	else
		conn.ip = conn.remoteAddress
	conn.verified = false
	for ipr in app.get('ipWhitelist')
		if cidrMatch.cidr_match conn.ip, ipr
			conn.verified = true
			break

	conn.writeJSON {type: 'localVerified', verified: conn.verified}
	console.log "#{ conn.id } (verified: #{ conn.verified }) connected from #{ conn.ip }"

	conn.on 'data', (message) ->
		data = JSON.parse(message)
		if data.type?
			conn.emit data.type, data
	conn.on 'initialize', ->
		lobby = lobby.filter (v) ->
			return v.id != conn.id
		if lobby.length > 0
			partner = lobby.shift()
			conn.partner = partner
			partner.partner = conn
			conn.writeJSON {type: 'createOffer'}
			conn.writeJSON {type: 'remoteVerified', verified: partner.verified}
			partner.writeJSON {type: 'remoteVerified', verified: conn.verified}
			console.log "Partnered #{ conn.id } with #{ partner.id }"
		else
			lobby.push conn

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
			conn.writeJSON {type: 'chat', self: true, message: data.message}
			conn.partner.writeJSON {type: 'chat', self: false, message: data.message}
			console.log "#{ dtNow() } #{ data.message }"

	leaveHandler = ->
		lobby = lobby.filter (v) ->
			return v.id != conn.id
		if conn.partner?
			conn.partner.writeJSON {type: 'leave'}
			conn.partner.partner = null

	conn.on 'leave', ->
		console.log "#{ conn.id } disconnected from their partner"
		leaveHandler() 

	conn.on 'close', (data) ->
		console.log "#{ conn.id } disconnected from the server"
		leaveHandler()
