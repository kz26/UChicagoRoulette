http = require 'http'
sockjs = require 'sockjs'
sanitize = require('validator').sanitize

chatServer = sockjs.createServer({
	prefix: '/controller',
	sockjs_url: 'http://cdn.sockjs.org/sockjs-0.3.min.js'
})

httpServer = http.createServer()
chatServer.installHandlers(httpServer)
httpServer.listen(8080)

lobby = []

lobbyRotate = ->
	if lobby.length > 0
		user = lobby.shift()
		user.writeJSON {type: 'refresh'}
	setTimeout lobbyRotate, 4000
lobbyRotate()

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
		if data.message?
			data.message = sanitize(data.message).entityEncode()
			conn.writeJSON data
			forwardHandler data

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
