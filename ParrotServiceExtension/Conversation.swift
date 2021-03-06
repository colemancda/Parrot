import Foundation

/// A Conversation is uniquely identified by its ID, and consists of
/// the current user, along with either one or more persons as well.
public protocol Conversation: ServiceOriginating /*: Hashable, Equatable*/ {
	
    typealias IdentifierType = String
    
	/// The Conversation's unique identifier (specific to the Service).
	var identifier: IdentifierType { get }
	
	/// The user-facing Conversation name. This may only be displayed if the
	/// conversation is a Group one, but this setting can be overridden.
	var name: String { get set }
	
	/// The set of people involved in this Conversation.
    var participants: [Person] { get }
    
	/// The focus information for each participant in the Conversation.
	/// There is guaranteed to be one Focus item per participant.
	var focus: [Person.IdentifierType: FocusMode] { get }
	
	/// The set of all events in this Conversation.
	var messages: [Message] { get }
	
	/// The number of messages that are unread for this Conversation.
	var unreadCount: Int { get }
	
	/// Whether the conversation's notifications will be presented to the user.
	var muted: Bool { get set }
    
    var archived: Bool { get set }
    
	/// Create a Conversation from the identifier given on the Service given.
    //init?(withIdentifier: String, on: Service)
		
	// leave()
	// archive()
	// delete()
    
	// watermark?
    
    func focus(mode: FocusMode)
    
    func send(message: Message) throws // MessageError
}

public extension Conversation {
    
    /// The timestamp used when sorting a list of recent conversations.
    public var sortTimestamp: Date {
        return self.messages.last?.timestamp ?? Date()
    }
}

public enum FocusMode {
    case away
    case here
    case typing
    case enteredText
}
