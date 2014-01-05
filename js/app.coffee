app = angular.module 'app', []

app.config ['$sceProvider', ($sceProvider) ->
	$sceProvider.enabled(false)
]

app.factory 'settings', ->
	return {
		sockUrl: 'http://172.245.60.168:8080/controller',
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
				{url: 'stun:stun.l.google.com:19302'}
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

MainCtrl = ($rootScope, $scope, $timeout, settings, moment, sockjs) ->
	if /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent)
		$scope.isMobile = true
		return
	if !getUserMedia
		$scope.noWebRTC = true
		return
	
	dtNow = ->
		return "[#{ moment().format('MM/DD/YYYY hh:mm A') }]"

	$scope.supported = true
	$scope.connected = false
	$scope.waiting = true
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
			$scope.closeConnection = ->
				try
					conn.close()
					console.log "Closed existing RTCPeerConnection"
				catch
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
						$scope.messages.push "<span class='blue'>#{ dtNow() } Connected to someone!</span>"
				sockjs.sendJSON {type: 'initialize'}
				console.log "Created new RTCPeerConnection"
			$scope.refresh = ->
				if !$scope.waiting
					$scope.closeConnection()
					sockjs.sendJSON {type: 'leave'}
				$scope.newConnection()
			$scope.nextUser = ->
				$scope.messages.push "<span class='blue'>#{ dtNow() } You disconnected</span>"
				$scope.messages.push "<span class='blue'>#{ dtNow() } Waiting for a partner...</span>"
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
				console.log "received remote candidate"
				conn.addIceCandidate(new RTCIceCandidate(data.candidate))	

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
				$scope.messages.push "#{ dtNow() } #{ data.message }"

			$rootScope.$on 'sockjs:remoteLeft', ->
				console.log "Remote left"
				$scope.waiting = true
				$scope.messages.push "<span class='blue'>#{ dtNow() } Your partner disconnected</span>"
				$scope.messages.push "<span class='blue'>#{ dtNow() } Waiting for a partner...</span>"
				$scope.closeConnection()
				$scope.newConnection()

			$rootScope.$on 'sockjs:close', ->
				$scope.closed = true

		sockjs.newSocket(settings.sockUrl)
	, (e) ->
		console.log "Webcam access denied - bailing"
		$scope.$apply ->
			$scope.gumDenied = true
