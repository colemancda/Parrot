import Foundation

public final class Client {
	
	// URL for uploading any URL to Photos
	public static let IMAGE_UPLOAD_URL = "https://docs.google.com/upload/photos/resumable"
	
	// NotificationCenter notification and userInfo keys.
	public static let didConnectNotification = Notification.Name(rawValue: "Hangouts.Client.DidConnect")
	public static let didReconnectNotification = Notification.Name(rawValue: "Hangouts.Client.DidReconnect")
	public static let didDisconnectNotification = Notification.Name(rawValue: "Hangouts.Client.DidDisconnect")
	public static let didUpdateStateNotification = Notification.Name(rawValue: "Hangouts.Client.UpdateState")
	public static let didUpdateStateKey = Notification.Name(rawValue: "Hangouts.Client.UpdateState.Key")
	
	// Timeout to send for setactiveclient requests:
	public static let ACTIVE_TIMEOUT_SECS = 120
	
	// Minimum timeout between subsequent setactiveclient requests:
	public static let SETACTIVECLIENT_LIMIT_SECS = 60
	
	public let config: URLSessionConfiguration
	public var channel: Channel?
	
	public var email: String?
	public var client_id: String?
	public var last_active_secs: NSNumber? = 0
	public var active_client_state: ActiveClientState?
	
	public init(configuration: URLSessionConfiguration) {
		self.config = configuration
    }
	
	private var tokens = [NSObjectProtocol]()
	
	// Establish a connection to the chat server.
    public func connect() {
		self.channel = Channel(configuration: self.config)
		//self.channel?.delegate = self
		self.channel?.listen()
		
		// 
		// A notification-based delegate replacement:
		//
		
		let _c = NotificationCenter.default()
		let a = _c.addObserver(forName: Channel.didConnectNotification, object: self.channel, queue: nil) { _ in
			NotificationCenter.default().post(name: Client.didConnectNotification, object: self)
		}
		let b = _c.addObserver(forName: Channel.didReconnectNotification, object: self.channel, queue: nil) { _ in
			NotificationCenter.default().post(name: Client.didReconnectNotification, object: self)
		}
		let c = _c.addObserver(forName: Channel.didDisconnectNotification, object: self.channel, queue: nil) { _ in
			NotificationCenter.default().post(name: Client.didDisconnectNotification, object: self)
		}
		let d = _c.addObserver(forName: Channel.didReceiveMessageNotification, object: self.channel, queue: nil) { note in
			if let val = (note.userInfo)?[Channel.didReceiveMessageKey.rawValue] as? [AnyObject] {
				self.channel(channel: self.channel!, didReceiveMessage: val)
			} else {
				print("Encountered an error! \(note)")
			}
		}
		self.tokens.append(contentsOf: [a, b, c, d])
    }
	
	/* TODO: Can't disconnect a Channel yet. */
	// Gracefully disconnect from the server.
	public func disconnect() {
		//self.channel?.disconnect()
		
		// Remove all the observers so we aren't receiving calls later on.
		self.tokens.forEach {
			NotificationCenter.default().removeObserver($0)
		}
	}
	
	// Use this method for constructing request messages when calling Hangouts APIs.
	private func getRequestHeader() -> [AnyObject] {
		return [
			[None /* 6 */, None /* 3 */, "parrot", None, None, None],
			[self.client_id ?? None, None],
			None,
			"en"
		]
	}
	
	// Use this method for constructing request messages when calling Hangouts APIs.
	public func generateClientID() -> Int {
		return Int(arc4random_uniform(2^32))
	}
	
	// Set this client as active.
	// While a client is active, no other clients will raise notifications.
	// Call this method whenever there is an indication the user is
	// interacting with this client. This method may be called very
	// frequently, and it will only make a request when necessary.
	public func setActive() {
		
		// If the client_id hasn't been received yet, we can't set the active client.
		guard self.client_id != nil else {
			print("Cannot set active client until client_id is received")
			return
		}
		
		let is_active = (active_client_state == ActiveClientState.IsActive)
		let time_since_active = (Date().timeIntervalSince1970 - last_active_secs!.doubleValue)
		let timed_out = time_since_active > Double(Client.SETACTIVECLIENT_LIMIT_SECS)
		
		if !is_active || timed_out {
			
			// Update these immediately so if the function is called again
			// before the API request finishes, we don't start extra requests.
			active_client_state = ActiveClientState.IsActive
			last_active_secs = Date().timeIntervalSince1970
			
			
			// The first time this is called, we need to retrieve the user's email address.
			if self.email == nil {
				self.getSelfInfo {
					self.email = $0!.selfEntity!.properties!.email[0] as String
				}
			}
			
			setActiveClient(is_active: true, timeout_secs: Client.ACTIVE_TIMEOUT_SECS)
        }
	}
	
	// Upload an image that can be later attached to a chat message.
	// The name of the uploaded file may be changed by specifying the filename argument.
	public func uploadImage(data: Data, filename: String, cb: ((String) -> Void)? = nil) {
		let json = "{\"protocolVersion\":\"0.8\",\"createSessionRequest\":{\"fields\":[{\"external\":{\"name\":\"file\",\"filename\":\"\(filename)\",\"put\":{},\"size\":\(data.count)}}]}}"
		
		self.channel?.base_request(path: Client.IMAGE_UPLOAD_URL,
			content_type: "application/x-www-form-urlencoded;charset=UTF-8",
			data: json.data(using: String.Encoding.utf8)!) { response in
			
			// Sift through JSON for a response with the upload URL.
				let _data: NSDictionary = try! JSONSerialization.jsonObject(with: response.data!,
				options: .allowFragments) as! NSDictionary
			let _a = _data["sessionStatus"] as! NSDictionary
			let _b = _a["externalFieldTransfers"] as! NSArray
			let _c = _b[0] as! NSDictionary
			let _d = _c["putInfo"] as! NSDictionary
			let upload = (_d["url"] as! NSString) as String
			
			self.channel?.base_request(path: upload, content_type: "application/octet-stream", data: data) { resp in
				
				// Sift through JSON for a response with the photo ID.
				let _data2: NSDictionary = try! JSONSerialization.jsonObject(with: resp.data!,
					options: .allowFragments) as! NSDictionary
				let _a2 = _data2["sessionStatus"] as! NSDictionary
				let _b2 = _a2["additionalInfo"] as! NSDictionary
				let _c2 = _b2["uploader_service.GoogleRupioAdditionalInfo"] as! NSDictionary
				let _d2 = _c2["completionInfo"] as! NSDictionary
				let _e2 = _d2["customerSpecificInfo"] as! NSDictionary
				let photoid = (_e2["photoid"] as! NSString) as String
				
				cb?(photoid)
			}
		}
	}
	
	// Parse channel array and call the appropriate events.
	public func channel(channel: Channel, didReceiveMessage message: [AnyObject]) {
		
		// Add services to the channel.
		//
		// The services we add to the channel determine what kind of data we will
		// receive on it. The "babel" service includes what we need for Hangouts.
		// If this fails for some reason, hangups will never receive any events.
		// This needs to be re-called whenever we open a new channel (when there's
		// a new SID and client_id.
		//
		// Based on what Hangouts for Chrome does over 2 requests, this is
		// trimmed down to 1 request that includes the bare minimum to make
		// things work.
		func addChannelServices() {
			let inner = ["3": ["1": ["1": "babel"]]]
			let dat = try! JSONSerialization.data(withJSONObject: inner, options: [])
			let str = NSString(data: dat, encoding: String.Encoding.utf8.rawValue) as! String
			
			self.channel?.sendMaps(mapList: [["p": str]])
		}
		
		guard message[0] as? String != "noop" else {
			return
		}
		
		// Wrapper appears to be a Protocol Buffer message, but encoded via
		// field numbers as dictionary keys. Since we don't have a parser
		// for that, parse it ad-hoc here.
		let thr = (message[0] as! [String: String])["p"]!
		let wrapper = try! thr.decodeJSON()
		
		// Once client_id is received, the channel is ready to have services added.
		if let id = wrapper["3"] as? [String: AnyObject] {
			self.client_id = (id["2"] as! String)
			addChannelServices()
		}
		if let cbu = wrapper["2"] as? [String: AnyObject] {
			let val2 = (cbu["2"]! as! String).data(using: String.Encoding.utf8)
			let payload = try! JSONSerialization.jsonObject(with: val2!, options: .allowFragments)
			
			// This is a (Client)BatchUpdate containing StateUpdate messages.
			// payload[1] is a list of state updates.
			if payload[0] as? String == "cbu" {
				var b = BatchUpdate() as ProtoMessage
				PBLiteSerialization.decode(message: &b, pblite: payload as! [AnyObject], ignoreFirstItem: true)
				for state_update in (b as! BatchUpdate).stateUpdate {
					self.active_client_state = state_update.stateUpdateHeader!.activeClientState!
					NotificationCenter.default().post(
						name: Client.didUpdateStateNotification, object: self,
						userInfo: [Client.didUpdateStateKey: Wrapper(state_update)])
				}
			} else {
				print("Ignoring message: \(payload[0])")
			}
		}
	}
	
	public func buildUserConversationList(cb: (UserList, ConversationList) -> Void) {
		
		// Retrieve recent conversations so we can preemptively look up their participants.
		self.syncRecentConversations { response in
			let conv_states = response!.conversationState
			let sync_timestamp = response!.syncTimestamp// use current_server_time?
			
			var required_user_ids = Set<UserID>()
			for conv_state in conv_states {
				let participants = conv_state.conversation!.participantData
				required_user_ids = required_user_ids.union(Set(participants.map {
					UserID(chatID: $0.id!.chatId!, gaiaID: $0.id!.gaiaId!)
				}))
			}
			
			var required_entities = [Entity]()
			self.getEntitiesByID(chat_id_list: required_user_ids.map { $0.chatID }) { resp in
				required_entities = resp?.entityResult.flatMap { $0.entity } ?? []
				
				// Let's request our own entity now.
				self.getSelfInfo {
					let selfUser = User(entity: $0!.selfEntity!, selfUser: nil)
					var users = [selfUser]
					
					// Add each entity as a new User.
					for entity in required_entities {
						let user = User(entity: entity, selfUser: selfUser.id)
						users.append(user)
					}
					
					let userList = UserList(client: self, me: selfUser, users: users)
					let conversationList = ConversationList(client: self, conv_states: conv_states, user_list: userList, sync_timestamp: sync_timestamp)
					cb(userList, conversationList)
				}
			}
		}
	}
	
    private func verifyResponseOK(responseObject: Data) {
		let parsedObject = try! JSONSerialization.jsonObject(with: responseObject, options: []) as? NSDictionary
        let status = ((parsedObject?["response_header"] as? NSDictionary) ?? NSDictionary())["status"] as? String
        if status != "OK" {
            print("Unexpected status response: \(parsedObject!)")
        }
    }
	
	// MARK - Client Requests
	
	// Add user to existing conversation.
	// conversation_id must be a valid conversation ID.
	// chat_id_list is list of users which should be invited to conversation.
	public func addUser(conversation_id: String, chat_id_list: [String], cb: ((response: AddUserResponse?) -> Void)? = nil) {
		let each = chat_id_list.map { [$0, None, None, "unknown", None, []] }
		let data = [
			self.getRequestHeader(),
			None,
			each,
			None,
			[
				[conversation_id],
				self.generateClientID(),
				2, None, 4
			]
		]
		self.channel?.request(endpoint: "conversations/adduser", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Create new conversation.
	// chat_id_list is list of users which should be invited to conversation (except from yourself).
	public func createConversation(chat_id_list: [String], force_group: Bool = false,
	                               cb: ((response: CreateConversationResponse?) -> Void)? = nil) {
		let each = chat_id_list.map { [$0, None, None, "unknown", None, []] }
		let data = [
			self.getRequestHeader(),
			(chat_id_list.count == 1 && !force_group) ? 1 : 2,
			self.generateClientID(),
			None,
			each
		]
		self.channel?.request(endpoint: "conversations/createconversation", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Delete one-to-one conversation.
	// conversation_id must be a valid conversation ID.
	public func deleteConversation(conversation_id: String, cb: ((response: DeleteConversationResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			[conversation_id],
			
			// Not sure what timestamp should be there, last time I have tried
			// it Hangouts client in GMail sent something like now() - 5 hours
			NSNumber(value: UInt64(Date().toUTC())),
			None,
			[]
		]
		self.channel?.request(endpoint: "conversations/deleteconversation", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Send a easteregg to a conversation.
	public func sendEasterEgg(conversation_id: String, easteregg: String, cb: ((response: EasterEggResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			[conversation_id],
			[easteregg, None, 1],
		]
		self.channel?.request(endpoint: "conversations/easteregg", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Return conversation events.
	// This is mainly used for retrieving conversation scrollback. Events
	// occurring before event_timestamp are returned, in order from oldest to
	// newest.
	public func getConversation(
		conversation_id: String,
		event_timestamp: Date,
		max_events: Int = 50,
		cb: (response: GetConversationResponse?) -> Void)
	{
		let data = [
			self.getRequestHeader(),
			[
				[conversation_id],
				[],
				[]
			],  // conversationSpec
			false,  // includeConversationMetadata
			true,  // includeEvents
			None,  // ???
			max_events,  // maxEventsPerConversation
			[
				None,  // eventId
				None,  // storageContinuationToken
				NSNumber(value: UInt64(event_timestamp.toUTC()))//to_timestamp(date: event_timestamp),  // eventTimestamp
			] // eventContinuationToken (specifying timestamp is sufficient)
		]
		
		self.channel?.request(endpoint: "conversations/getconversation", body: data, use_json: false) { r in
			cb(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Return information about a list of contacts.
	public func getEntitiesByID(chat_id_list: [String], cb: (response: GetEntityByIdResponse?) -> Void) {
		guard chat_id_list.count > 0 else { cb(response: nil); return }
		let data = [
			self.getRequestHeader(),
			None,
			chat_id_list.map { [$0] }
		]
		/*
		self.request(endpoint: "contacts/getentitybyid", body: data) { r in
			print("\(NSString(data: r.data!, encoding: String.Encoding.utf8.rawValue))")
		}*/
		self.channel?.request(endpoint: "contacts/getentitybyid", body: data, use_json: false) { r in
			cb(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	public func getSelfInfo(cb: ((response: GetSelfInfoResponse?) -> Void)) {
		let data = [
			self.getRequestHeader()
		]
		self.channel?.request(endpoint: "contacts/getselfinfo", body: data, use_json: false) { r in
			cb(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	public func getSuggestedEntities(max_count: Int, cb: ((response: GetSuggestedEntitiesResponse?) -> Void)) {
		let data = [
			self.getRequestHeader(),
			None,
			None,
			max_count
		]
		self.channel?.request(endpoint: "contacts/getsuggestedentities", body: data, use_json: false) { r in
			cb(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	public func queryPresence(chat_ids: [String] = [],
	                          reachable: Bool = true,
	                          available: Bool = true,
	                          mood: Bool = true,
	                          inCall: Bool = true,
	                          device: Bool = true,
	                          lastSeen: Bool = true,
	                          cb: ((response: QueryPresenceResponse?) -> Void)) {
		guard chat_ids.count > 0 else {
			print("Cannot query presence for zero chat IDs!")
			return
		}
		
		let data = [
			self.getRequestHeader(),
			[chat_ids],
			[1, 2, 3, 4, 5, 6, 7, 8, 9, 10] // what are FieldMasks 4, 5, 8, 9?
		]
		self.channel?.request(endpoint: "presence/querypresence", body: data, use_json: false) { r in
			cb(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Leave group conversation.
	// conversation_id must be a valid conversation ID.
	public func removeUser(conversation_id: String, cb: ((response: RemoveUserResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			None,
			None,
			None,
			[
				[conversation_id],
				generateClientID(),
				2
			],
		]
		self.channel?.request(endpoint: "conversations/removeuser", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Set the name of a conversation.
	public func renameConversation(conversation_id: String, name: String, cb: ((response: RenameConversationResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			None,
			name,
			None,
			[
				[conversation_id],
				generateClientID(),
				1
			]
		]
		self.channel?.request(endpoint: "conversations/renameconversation", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Search for people.
	public func searchEntities(search_string: String, max_results: Int, cb: ((response: SearchEntitiesResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			[],
			search_string,
			max_results,
		]
		self.channel?.request(endpoint: "conversations/searchentities", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Send a chat message to a conversation.
	// conversation_id must be a valid conversation ID. segments must be a
	// list of message segments to send, in pblite format.
	// otr_status determines whether the message will be saved in the server's
	// chat history. Note that the OTR status of the conversation is
	// irrelevant, clients may send messages with whatever OTR status they
	// like.
	// image_id is an option ID of an image retrieved from
	// Client.upload_image. If provided, the image will be attached to the
	// message.
	public func sendChatMessage(conversation_id: String,
		segments: [NSArray],
		image_id: String? = nil,
		image_user_id: String? = nil,
		otr_status: OffTheRecordStatus = .OnTheRecord,
		delivery_medium: DeliveryMediumType = .Babel,
		cb: ((response: SendChatMessageResponse?) -> Void)? = nil)
	{
		// Support sending images from other user id's.
		var a: NSObject
		if image_id != nil {
			if image_user_id != nil {
				a = [[image_id!, false, image_user_id!, true]]
			} else {
				a = [[image_id!, false, None, false]]
			}
		} else {
			a = None
		}
		
		let data = [
			self.getRequestHeader(),
			None,
			None,
			None,
			[], //EventAnnotation
			[ //ChatMessageContent
				segments,
				[]
			],
			a, // it's too long for one line! // ExistingMedia
			[ //EventRequestHeader
				[conversation_id],
				generateClientID(),
				otr_status.rawValue,
				[delivery_medium.rawValue],
				None, //NSNumber(value: EventType.Sms.rawValue)
			],
			//None,
			//None,
			//None,
			//[]
		]
		
		// sendchatmessage can return 200 but still contain an error
		self.channel?.request(endpoint: "conversations/sendchatmessage", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	public func setActiveClient(is_active: Bool, timeout_secs: Int,
	                            cb: ((response: SetActiveClientResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			is_active, // whether the client is active or not
			"\(self.email!)/" + (self.client_id ?? ""), // full_jid: user@domain/resource
			timeout_secs // timeout in seconds for this client to be active
		]
		
		// Set the active client.
		self.channel?.request(endpoint: "clients/setactiveclient", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	public func setConversationNotificationLevel(conversation_id: String, level: NotificationLevel = .Ring,
	                                             cb: ((response: SetConversationNotificationLevelResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			[conversation_id]
		]
		self.channel?.request(endpoint: "conversations/setconversationnotificationlevel", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Set focus (occurs whenever you give focus to a client).
	public func setFocus(conversation_id: String, focused: Bool = true,
	                     cb: ((response: SetFocusResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			[conversation_id],
			focused ? 1 : 2,
			20
		]
        self.channel?.request(endpoint: "conversations/setfocus", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
    }
	
	/* TODO: Does not return data, only calls the callback. */
	public func setPresence(online: Bool, mood: String?,
	                        cb: ((response: SetPresenceResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			[
				720, // timeout_secs timeout in seconds for this presence
				
				//client_presence_state:
				// 40 => DESKTOP_ACTIVE
				// 30 => DESKTOP_IDLE
				// 1 => nil
				(online ? 1 : 40)
			],
			None,
			None,
			[!online], // True if going offline, False if coming online
			[mood ?? None] // UTF-8 smiley like 0x1f603
		]
		self.channel?.request(endpoint: "presence/setpresence", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Send typing notification.
	public func setTyping(conversation_id: String, typing: TypingType = TypingType.Started,
	                      cb: ((response: SetTypingResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			[conversation_id],
			NSNumber(value: typing.rawValue)
		]
		self.channel?.request(endpoint: "conversations/settyping", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// List all events occurring at or after a timestamp.
	public func syncAllNewEvents(timestamp: Date, cb: (response: SyncAllNewEventsResponse?) -> Void) {
		let data: NSArray = [
			self.getRequestHeader(),
			NSNumber(value: UInt64(timestamp.toUTC())),//to_timestamp(date: timestamp),
			[],
			None,
			[],
			false,
			[],
			1048576 // max_response_size_bytes
		]
		self.channel?.request(endpoint: "conversations/syncallnewevents", body: data, use_json: false) { r in
			cb(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
		
		// This method requests protojson rather than json so we have one chat
		// message parser rather than two.
		// timestamp: datetime.datetime instance specifying the time after
		// which to return all events occurring in.
	}
	
	// Return info on recent conversations and their events.
	public func syncRecentConversations(maxConversations: Int = 100, maxEventsPer: Int = 1,
		cb: ((response: SyncRecentConversationsResponse?) -> Void)) {
		let data = [
			self.getRequestHeader(),
			None,
			maxConversations,
			maxEventsPer,
			[1]
		]
		self.channel?.request(endpoint: "conversations/syncrecentconversations", body: data, use_json: false) { r in
			cb(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
	
	// Update the watermark (read timestamp) for a conversation.
	public func updateWatermark(conv_id: String, read_timestamp: Date, cb: ((response: UpdateWatermarkResponse?) -> Void)? = nil) {
		let data = [
			self.getRequestHeader(),
			[conv_id], // conversation_id
			NSNumber(value: UInt64(read_timestamp.toUTC()))//to_timestamp(date: ), // latest_read_timestamp
		]
		self.channel?.request(endpoint: "conversations/updatewatermark", body: data, use_json: false) { r in
			cb?(response: PBLiteSerialization.parseProtoJSON(input: r.data!))
		}
	}
}
