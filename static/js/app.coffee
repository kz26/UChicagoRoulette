app = angular.module 'app', []

app.config ['$sceProvider', ($sceProvider) ->
	$sceProvider.enabled(false)
]

app.factory 'settings', ->
	return {
		sockUrl: 'http://uchicagoroulette.com/server',
		gumConf: {
			audio: true,
			video: {
				mandatory: {
					minWidth: 640,
					maxWidth: 640,
					minHeight: 480,
					maxHeight: 480
				}
			}
		},
		peerConf: {
			iceServers: [
				createIceServer('stun:stun.l.google.com:19302'),
				createIceServer('stun:stunserver.org'),
				createIceServer('stun:stun01.sipphone.com'),
				createIceServer('stun:stun.ekiga.net'),
				createIceServer('stun:stun.fwdnet.net'),
				createIceServer('turn:wlsvps1.mooo.com:3478', 'uchicago', 'roulette')
			]
		}
	}

app.factory 'moment', ->
	return moment

app.factory 'sockjs', ($rootScope) ->
	sockjs = {}
	sockjs.newSocket = (url) ->
		socket = new SockJS(url)
		socket.onopen = ->
			$rootScope.$apply ->
				$rootScope.$broadcast 'sockjs:open'
		socket.onmessage = (e) ->
			$rootScope.$apply ->
				$rootScope.$broadcast 'sockjs:message', e.data
		socket.onerror = (e) ->
			$rootScope.$apply ->
				$rootScope.$broadcast 'sockjs:error', e.data
		socket.onclose = ->
			$rootScope.$apply ->
				$rootScope.$broadcast 'sockjs:close'
		sockjs.socket = socket
		sockjs.sendJSON = (data) ->
			socket.send JSON.stringify(data)
	$rootScope.$on 'sockjs:message', (e, data) ->
		data = JSON.parse(data)
		if data.type?
			$rootScope.$broadcast "sockjs:#{data.type}", data
	return sockjs

app.directive 'scrollBottom', ($timeout) ->
	return (scope, element, attrs) ->
		scope.$watch 'messages.length', ->
			$timeout ->
				element.animate {scrollTop: element.prop("scrollHeight")}, 'fast'
			, 10

MainCtrl = ($rootScope, $scope, $timeout, settings, moment, sockjs) ->
	if !getUserMedia
		$scope.noWebRTC = true
		return
	
	dtNow = ->
		return "[#{ moment().format('MM/DD/YYYY hh:mm:ss A') }]"

	$scope.supported = true
	$scope.connected = false
	$scope.waiting = true
	$scope.localVerified = false
	$scope.remoteVerified = false
	$scope.messages = []
	getUserMedia {audio: true, video: true}, (stream) ->
		attachMediaStream($('#local-video')[0], stream)
		$scope.toggleLocalStream = (type) ->
			tracks = null
			if type == 'audio'
				tracks = stream.getAudioTracks()
			else
				tracks = stream.getVideoTracks()
			for t in tracks
				t.enabled = !t.enabled
		conn = null
		$rootScope.$on 'sockjs:open', ->
			$scope.connected = true
			$scope.messages.push "<span class='text-success'>#{ dtNow() } Connection to matchmaking server established.</span>"
			$scope.messages.push "<span class='text-info'>#{ dtNow() } Waiting for a partner...</span>"
			$scope.closeConnection = ->
				try
					conn.close()
					console.log "Closed existing RTCPeerConnection"
				catch e
					console.log "RTCPeerConnection already closed"
				$scope.waiting = true
			$scope.newConnection = ->
				$scope.waiting = true
				conn = new RTCPeerConnection(settings.peerConf)
				conn.addStream(stream)
				conn.onicecandidate = (e) ->
					$scope.$apply ->
						console.log "onicecandidate triggered"
						if e.candidate
							sockjs.sendJSON {type: 'candidate', candidate: e.candidate}
				conn.onaddstream = (e) ->
					$scope.$apply ->
						console.log "Attaching remote stream"
						attachMediaStream($('#remote-video')[0], e.stream)
						$scope.waiting = false
						$scope.messages.push "<span class='text-success'>#{ dtNow() } Connected to someone!</span>"
				$timeout ->
					sockjs.sendJSON {type: 'initialize'}
				, 500
				console.log "Created new RTCPeerConnection"
			$scope.refresh = ->
				if !$scope.waiting
					sockjs.sendJSON {type: 'leave'}
				$scope.closeConnection()
				$scope.newConnection()
			$scope.nextUser = (local) -> # local = true if disconnect was initiated locally
				if local
					$scope.messages.push "<span class='text-danger'>#{ dtNow() } You disconnected</span>"
				else
					$scope.messages.push "<span class='text-danger'>#{ dtNow() } Your partner disconnected</span>"
				$scope.messages.push "<span class='text-info'>#{ dtNow() } Waiting for a partner...</span>"
				$scope.refresh()
			$scope.sendChatMessage = ->
				if $scope.chatMessage.length > 0
					sockjs.sendJSON {type: 'chat', message: $scope.chatMessage}
				$scope.chatMessage = ''
				
			$scope.newConnection()

			$rootScope.$on 'sockjs:refresh', ->
				$scope.refresh()

			$rootScope.$on 'sockjs:requestOffer', ->
				conn.createOffer (desc) ->
					conn.setLocalDescription desc, ->
						console.log "sent SDP offer"
						sockjs.sendJSON {type: 'offer', sdp: desc}
				, (err) ->
					console.log err

			$rootScope.$on 'sockjs:candidate', (e, data) ->
				conn.addIceCandidate new RTCIceCandidate(data.candidate)
				console.log "added remote ICE candidate"

			$rootScope.$on 'sockjs:sdp',(e, data) ->
				console.log "received remote SDP"
				conn.setRemoteDescription new RTCSessionDescription(data.sdp), ->
					if conn.remoteDescription.type == 'offer'
						conn.createAnswer (desc) ->
							conn.setLocalDescription desc, ->
								console.log "sent SDP answer"
								sockjs.sendJSON {type: 'sdp', sdp: desc}
						, (err) ->
							console.log err
				, (err) ->
					console.log err

			$rootScope.$on 'sockjs:chat', (e, data) ->
				from = null
				if data.self
					from = 'You'
				else
					from = 'Them'
				$scope.messages.push "#{ dtNow() } <b>#{ from }:</b> #{ data.message }"

			$rootScope.$on 'sockjs:localVerified', (e, data) ->
				$scope.localVerified = data.verified
			$rootScope.$on 'sockjs:remoteVerified', (e, data) ->
				$scope.remoteVerified = data.verified

			$rootScope.$on 'sockjs:remoteLeft', ->
				console.log "Remote left"
				$scope.waiting = true
				$scope.nextUser(false)

			$rootScope.$on 'sockjs:close', ->
				$scope.closed = true

		sockjs.newSocket(settings.sockUrl)
	, (e) ->
		console.log "Webcam access denied - bailing"
		$scope.$apply ->
			$scope.gumDenied = true
