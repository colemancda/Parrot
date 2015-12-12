import Foundation

protocol ConversationDelegate {
    func conversation(conversation: Conversation, didChangeTypingStatusForUser: User, toStatus: TypingType)
    func conversation(conversation: Conversation, didReceiveEvent: ConversationEvent)
    func conversation(conversation: Conversation, didReceiveWatermarkNotification: WatermarkNotification)
    func conversationDidUpdateEvents(conversation: Conversation)

    //  The conversation did receive an update to its internal state - 
    //  the sort timestamp probably changed, at least.
    func conversationDidUpdate(conversation: Conversation)
}

// Wrapper around Client for working with a single chat conversation.
class Conversation {
    typealias EventID = String

    var client: Client
    var user_list: UserList
    var conversation: CLIENT_CONVERSATION
    var events_dict: Dictionary<EventID, ConversationEvent> = Dictionary<EventID, ConversationEvent>() {
        didSet {
            self._cachedEvents = nil
        }
    }
    var typingStatuses = Dictionary<UserID, TypingType>()

    var delegate: ConversationDelegate?
    var conversationList: ConversationList?

    init(client: Client,
        user_list: UserList,
        client_conversation: CLIENT_CONVERSATION,
        client_events: [CLIENT_EVENT] = [],
        conversationList: ConversationList
    ) {
        self.client = client
        self.user_list = user_list
        self.conversation = client_conversation
        self.conversationList = conversationList

        for event in client_events {
            add_event(event)
        }
    }
	
	// Update the conversations latest_read_timestamp.
    func on_watermark_notification(notif: WatermarkNotification) {
        if self.get_user(notif.user_id).isSelf {
            self.conversation.self_conversation_state.self_read_state.latest_read_timestamp = notif.read_timestamp
        }
    }
	
	// Update the internal Conversation.
	// When latest_read_timestamp is 0, this seems to indicate no change
	// from the previous value. Word around this by saving and restoring the
	// previous value.
    func update_conversation(client_conversation: CLIENT_CONVERSATION) {
        let old_timestamp = self.latest_read_timestamp
        self.conversation = client_conversation
        
        if to_timestamp(self.latest_read_timestamp) == 0 {
            self.conversation.self_conversation_state.self_read_state.latest_read_timestamp = old_timestamp
        }

        delegate?.conversationDidUpdate(self)
    }
	
	// Wrap ClientEvent in ConversationEvent subclass.
    private class func wrap_event(event: CLIENT_EVENT) -> ConversationEvent {
        if event.chat_message != nil {
            return ChatMessageEvent(client_event: event)
        } else if event.conversation_rename != nil {
            return RenameEvent(client_event: event)
        } else if event.membership_change != nil {
            return MembershipChangeEvent(client_event: event)
        } else {
            return ConversationEvent(client_event: event)
        }
    }

    private var _cachedEvents = [ConversationEvent]?()
    var events: [ConversationEvent] {
        get {
            if _cachedEvents == nil {
                _cachedEvents = events_dict.values.sort { $0.timestamp < $1.timestamp }
            }
            return _cachedEvents!
        }
    }
	
	// Add a ClientEvent to the Conversation.
	// Returns an instance of ConversationEvent or subclass.
    func add_event(event: CLIENT_EVENT) -> ConversationEvent {
        let conv_event = Conversation.wrap_event(event)
        self.events_dict[conv_event.id] = conv_event
        return conv_event
    }
	
	// Return the User instance with the given UserID.
    func get_user(user_id: UserID) -> User {
        return self.user_list.get_user(user_id)
    }

    var otherUserIsTyping: Bool {
        get {
            return self.typingStatuses.filter {
                (k, v) in !self.user_list.get_user(k).isSelf
            }.map {
                (k, v) in v == TypingType.STARTED
            }.first ?? false
        }
    }

    func setFocus() {
        self.client.setFocus(id)
    }
	
	// Send a message to this conversation.
	// A per-conversation lock is acquired to ensure that messages are sent in
	// the correct order when this method is called multiple times
	// asynchronously.
	// segments is a list of ChatMessageSegments to include in the message.
	// image_file is an optional file-like object containing an image to be
	// attached to the message.
	// image_id is an optional ID of an image to be attached to the message
	// (if you specify both image_file and image_id together, image_file
	// takes precedence and supplied image_id will be ignored)
	// Send messages with OTR status matching the conversation's status.
    func sendMessage(segments: [ChatMessageSegment],
        image_file: String? = nil,
        image_id: String? = nil,
        cb: (() -> Void)? = nil
    ) {
        let otr_status = (is_off_the_record ? OffTheRecordStatus.OFF_THE_RECORD : OffTheRecordStatus.ON_THE_RECORD)

        if let _ = image_file {
			self.sendMessage(segments, image_file: nil, image_id: image_id, cb: cb)
            return
        }

        client.sendChatMessage(id,
            segments: segments.map { $0.serialize() },
            image_id: image_id,
            otr_status: otr_status,
            cb: cb
        )
    }

    func leave(cb: (() -> Void)? = nil) {
        switch (self.conversation.type) {
        case ConversationType.GROUP:
            print("Remove Not Implemented!")
            //client.removeUser(id, cb)
        case ConversationType.ONE_TO_ONE:
            client.deleteConversation(id, cb: cb)
        default:
            break
        }
    }
    
	
	// Rename the conversation.
	// Hangouts only officially supports renaming group conversations, so
	// custom names for one-to-one conversations may or may not appear in all
	// first party clients.
    func rename(name: String, cb: (() -> Void)?) {
        self.client.setChatName(self.id, name: name, cb: cb)
    }

//    func set_notification_level(level, cb: (() -> Void)?) {
//        // Set the notification level of the conversation.
//        // Pass ClientNotificationLevel.QUIET to disable notifications,
//        // or ClientNotificationLevel.RING to enable them.
//        self.client.setconversationnotificationlevel(self.id_, level, cb)
//    }
	
	// Set typing status.
	// TODO: Add rate-limiting to avoid unnecessary requests.
    func setTyping(typing: TypingType = TypingType.STARTED, cb: (() -> Void)? = nil) {
        client.setTyping(id, typing: typing, cb: cb)
    }
	
	// Update the timestamp of the latest event which has been read.
	// By default, the timestamp of the newest event is used.
	// This method will avoid making an API request if it will have no effect.
    func updateReadTimestamp(var read_timestamp: NSDate? = nil, cb: (() -> Void)? = nil) {
        if read_timestamp == nil {
            read_timestamp = self.events.last!.timestamp
        }
        if let new_read_timestamp = read_timestamp {
            if new_read_timestamp > self.latest_read_timestamp {

                // Prevent duplicate requests by updating the conversation now.
                latest_read_timestamp = new_read_timestamp
                delegate?.conversationDidUpdate(self)
                conversationList?.conversationDidUpdate(self)
                client.updateWatermark(id, read_timestamp: new_read_timestamp, cb: cb)
            }
        }
    }

    func handleConversationEvent(event: ConversationEvent) {
        if let delegate = delegate {
            delegate.conversation(self, didReceiveEvent: event)
        } else {
            let user = user_list.get_user(event.user_id)
            if !user.isSelf {
				print("");
                //NotificationManager.sharedInstance.sendNotificationFor(event, fromUser: user)
            }
        }
    }

    func handleTypingStatus(status: TypingType, forUser user: User) {
        let existingTypingStatus = typingStatuses[user.id]
        if existingTypingStatus == nil || existingTypingStatus! != status {
            typingStatuses[user.id] = status
            delegate?.conversation(self, didChangeTypingStatusForUser: user, toStatus: status)
        }
    }

    func handleWatermarkNotification(status: WatermarkNotification) {
        delegate?.conversation(self, didReceiveWatermarkNotification: status)
    }

    var messages: [ChatMessageEvent] {
        get {
            return events.flatMap { $0 as? ChatMessageEvent }
        }
    }
	
	// Return list of ConversationEvents ordered newest-first.
	// If event_id is specified, return events preceeding this event.
	// This method will make an API request to load historical events if
	// necessary. If the beginning of the conversation is reached, an empty
	// list will be returned.
    func getEvents(event_id: String? = nil, max_events: Int = 50, cb: (([ConversationEvent]) -> Void)? = nil) {
        guard let event_id = event_id else {
            cb?(events)
            return
        }

        // If event_id is provided, return the events we have that are
        // older, or request older events if event_id corresponds to the
        // oldest event we have.
        if let conv_event = self.get_event(event_id) {
            if events.first!.id != event_id {
                if let indexOfEvent = self.events.indexOf({ $0 == conv_event }) {
                    cb?(Array(self.events[indexOfEvent...self.events.endIndex]))
                    return
                }
            }
			
            client.getConversation(id, event_timestamp: conv_event.timestamp, max_events: max_events) { res in
                let conv_events = res.conversation_state.event.map { Conversation.wrap_event($0) }

                for conv_event in conv_events {
                    self.events_dict[conv_event.id] = conv_event
                }
                cb?(conv_events)
                self.delegate?.conversationDidUpdateEvents(self)
            }
        } else {
            print("Event not found.")
        }
    }

//    func next_event(event_id, prev=False) {
//        // Return ConversationEvent following the event with given event_id.
//        // If prev is True, return the previous event rather than the following
//        // one.
//        // Raises KeyError if no such ConversationEvent is known.
//        // Return nil if there is no following event.
//
//        i = self.events.index(self._events_dict[event_id])
//        if prev and i > 0:
//        return self.events[i - 1]
//        elif not prev and i + 1 < len(self.events) {
//            return self.events[i + 1]
//            else:
//            return nil
//        }
//    }

    func get_event(event_id: EventID) -> ConversationEvent? {
        return events_dict[event_id]
    }
	
	// The conversation's ID.
    var id: String {
        get {
            return self.conversation.conversation_id!.id as String
        }
    }

    var users: [User] {
        get {
            return conversation.participant_data.map {
                self.user_list.get_user(UserID(
                    chat_id: $0.id.chat_id as String,
                    gaia_id: $0.id.gaia_id as String
                ))
            }
        }
    }

    var name: String {
        get {
            if let name = self.conversation.name {
                return name as String
            } else {
                return users.filter { !$0.isSelf }.map { $0.full_name }.joinWithSeparator(", ")
            }
        }
    }

    var last_modified: NSDate {
        get {
            return conversation.self_conversation_state.sort_timestamp!
        }
    }
	
	// datetime timestamp of the last read ConversationEvent.
    var latest_read_timestamp: NSDate {
        get {
            return conversation.self_conversation_state.self_read_state.latest_read_timestamp
        }
        set(newLatestReadTimestamp) {
            conversation.self_conversation_state.self_read_state.latest_read_timestamp = newLatestReadTimestamp
        }
    }
	
	// List of ConversationEvents that are unread.
	// Events are sorted oldest to newest.
	// Note that some Hangouts clients don't update the read timestamp for
	// certain event types, such as membership changes, so this method may
	// return more unread events than these clients will show. There's also a
	// delay between sending a message and the user's own message being
	// considered read.
    var unread_events: [ConversationEvent] {
        get {
            return events.filter { $0.timestamp > self.latest_read_timestamp }
        }
    }

    var hasUnreadEvents: Bool {
        get {
            if unread_events.first != nil {
                print("Conversation \(name) has unread events, latest read timestamp is \(self.latest_read_timestamp)")
            }
            return unread_events.first != nil
        }
    }
	
	// True if this conversation has been archived.
    var is_archived: Bool {
        get {
            return self.conversation.self_conversation_state.view.contains(ConversationView.ARCHIVED)
        }
    }
    
//        var is_quiet {
//            get {
//                // True if notification level for this conversation is quiet.
//                level = self._conversation.self_conversation_state.notification_level
//                return level == ClientNotificationLevel.QUIET
//            }
//        }
//        
	
	// True if conversation is off the record (history is disabled).
    var is_off_the_record: Bool {
        get {
            return self.conversation.otr_status == OffTheRecordStatus.OFF_THE_RECORD
        }
    }
}