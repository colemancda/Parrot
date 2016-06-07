import Foundation

// FIXME: syntax, imports, packages, map field types
// TODO: Does not support: services, extensions, options, inner class, oneof

private let COMMENT_REGEX = "((?:\\/\\*)(?:[\\s\\S]*)(?:\\*\\/))|((?:\\/\\/)(?:.*))"
private let MESSAGE_REGEX = "(?:message)(?:[\\s\\S]*?)(?:\\{)(?:[\\s\\S]*?)(?:\\})"
private let ENUM_REGEX = "(?:enum)(?:[\\s\\S]*?)(?:\\{)(?:[\\s\\S]*?)(?:\\})"
private let FIELD_REGEX = "(?:(required|optional|repeated))(?:.*)(?:\\;)"

// Because Swift. :D
public protocol Initializable {
	init()
}

public protocol ProtoEnum: RawRepresentable, Hashable, Equatable {
	// nothing here, just a dummy!
}

public protocol ProtoMessage: Initializable, CustomStringConvertible, CustomDebugStringConvertible, Hashable, Equatable {
	static var _protoFields: [Int: ProtoFieldDescriptor] { get }
	var _unknownFields: [Int: Any] { get set }
	
	mutating func set(name: String, value: Any?) throws
	func get(name: String) throws -> Any?
}

// Message: Builder Support
public extension ProtoMessage {
	public init(fields: [Int: Any?]) throws {
		self.init()
		for (idx, desc) in Self._protoFields {
			if let val = fields[idx] {
				try self.set(name: desc.name, value: val)
			} else if desc.label == .required {
				throw ProtoError.requiredFieldError
			}
		}
	}
	public init(test: String, builder: (inout Self) -> Void) {
		self.init()
		builder(&self)
	}
}

// Message: String & DebugStringConvertible Support
public extension ProtoMessage /* : CustomStringConvertible, CustomDebugStringConvertible */{
	
	var description: String {
		return "message \(_typeName(self.dynamicType)) { ... }"
	}
	
	public var debugDescription: String {
		return "message \(_typeName(self.dynamicType)) { ... }"
	}
	
	public func _toProto(_ indent: String = "", _ value: Bool = false) -> String {
		var output = ""
		for (_, field) in Self._protoFields {
			output += "\(indent)\(field.label) \(field.type) \(field.name) = \(field.id);\n"
		}
		return output
	}
}

// Message: Hashable & Equatable Support
public extension ProtoMessage /* : Hashable, Equatable */ {
	public var hashValue: Int {
		return 0
	}
}
public func ==<T: ProtoMessage>(lhs: T, rhs: T) -> Bool {
	return lhs.hashValue == rhs.hashValue
}

// Message: Convenience id -> property mapping
public extension ProtoMessage {
	
	mutating func set(id: Int, value: Any?) throws {
		if let name = Self._protoFields[id]?.name {
			try set(name: name, value: value)
		} else {
			throw ProtoError.fieldNameNotFoundError
		}
	}
	
	func get(id: Int) throws -> Any? {
		if let name = Self._protoFields[id]?.name {
			return try get(name: name)
		} else {
			throw ProtoError.fieldNameNotFoundError
		}
	}
}

public enum ProtoImportDescriptor {
	case weak(String)
	case `public`(String)
}

public enum ProtoFieldLabel: String {
	case required, repeated, optional
}

public struct ProtoFieldDescriptor {
	public let id: Int
	public let name: String
	public let type: ProtoFieldType
	public let label: ProtoFieldLabel
	
	public var camelName: String {
		let comps = self.name.components(separatedBy: "_")
		return comps.dropFirst()
			.map { $0.capitalized }
			.reduce(comps.first!, combine: +)
	}
}

public enum ProtoFieldType {
	case string
	case bytes
	case bool
	case double, float
	case int32, int64
	case uint32, uint64
	case sint32, sint64
	case fixed32, fixed64
	case sfixed32, sfixed64
	case prototype(String)
	
	public init(extendedGraphemeClusterLiteral value: String) {
		self.init(stringLiteral: value)
	}
	public init(unicodeScalarLiteral value: String) {
		self.init(stringLiteral: value)
	}
	public init(stringLiteral value: String) {
		switch value {
		case "string": self = .string
		case "bytes": self = .bytes
		case "bool": self = .bool
		case "double": self = .double
		case "float": self = .float
		case "int32": self = .int32
		case "int64": self = .int64
		case "uint32": self = .uint32
		case "uint64": self = .uint64
		case "sint32": self = .sint32
		case "sint64": self = .sint64
		case "fixed32": self = .fixed32
		case "fixed64": self = .fixed64
		case "sfixed32": self = .sfixed32
		case "sfixed64": self = .sfixed64
		default: self = .prototype(value)
		}
	}
	
	public var prototyped: Bool {
		switch self {
		case prototype(_): return true
		default: return false
		}
	}
	
	public var type: String {
		switch self {
		case string: return "String"
		case bytes: return "String"
		case bool: return "Bool"
		case double: return "Double"
		case float: return "Float"
		case uint32: return "UInt32"
		case uint64: return "UInt64"
		case int32, sint32, fixed32, sfixed32: return "Int32"
		case int64, sint64, fixed64, sfixed64: return "Int64"
		case prototype(let name): return name
		}
	}
	
	public func type(labeled label: ProtoFieldLabel) -> String {
		switch label {
		case .optional: return "\(self.type)?"
		case .required: return "\(self.type)"
		case .repeated: return "[\(self.type)]"
		}
	}
	
	public func container(labeled label: ProtoFieldLabel) -> String {
		switch label {
		case .optional: return "\(self.type)?"
		case .required: return "\(self.type)!"
		case .repeated: return "[\(self.type)] = []"
		}
	}
}

public enum ProtoError: ErrorProtocol {
	case typeMismatchError
	case requiredFieldError
	case fieldNameNotFoundError
	case fieldIdNotFoundError
}

public struct ProtoEnumDescriptor {
	public let name: String
	public let values: [(Int, String)]
	
	public static func fromString(string: String) throws -> ProtoEnumDescriptor {
		guard var title = string.substring(between: "enum ", and: " {") else {
			throw NSError()
		}
		guard let content = string.substring(between: "{", and: "}") else {
			throw NSError()
		}
		
		let f2 = content.components(separatedBy: ";").map {
			$0.trimmingCharacters(in: .whitespacesAndNewlines())
		}.filter { !$0.isEmpty } as [String]
		let fields = f2.map {
			let a = $0.components(separatedBy: " ").filter { $0 != "=" }
			return (Int(a[1])!, a[0])
		}.sorted { $0.0 < $1.0 } as [(Int, String)]
		
		title = title.trimmingCharacters(in: .whitespacesAndNewlines())
		return ProtoEnumDescriptor(name: title, values: fields)
	}
	
	public func toString() -> String {
		var output = "public enum \(self.name): Int, ProtoEnum {\n"
		self.values.forEach { k, v in
			let comps = v.components(separatedBy: "_")
			let name = comps.dropFirst()
				.map { $0.capitalized }
				.reduce(comps.first!.capitalized, combine: +)
				.replacingOccurrences(of: self.name, with: "", options: .caseInsensitiveSearch)
			
			output += "\tcase \(name) = \(k)\n"
		}
		return output + "}"
	}
}

public struct ProtoMessageDescriptor {
	public let name: String
	public let fields: [ProtoFieldDescriptor]
	
	public static func fromString(string: String) throws -> ProtoMessageDescriptor {
		guard var title = string.substring(between: "message ", and: " {") else {
			throw NSError()
		}
		guard let content = string.substring(between: "{", and: "}") else {
			throw NSError()
		}
		
		let f2 = content.components(separatedBy: ";").map {
			$0.trimmingCharacters(in: .whitespacesAndNewlines())
			}.filter { !$0.isEmpty } as [String]
		let fields = f2.map {
			let a = $0.components(separatedBy: " ").filter { $0 != "=" }.filter { !$0.isEmpty }
			return ProtoFieldDescriptor(id: Int(a[3])!, name: a[2],
			                       type: ProtoFieldType(stringLiteral: a[1]),
			                       label: ProtoFieldLabel(rawValue: a[0])!)
			} as [ProtoFieldDescriptor]
		
		title = title.trimmingCharacters(in: .whitespacesAndNewlines())
		return ProtoMessageDescriptor(name: title, fields: fields)
	}
	
	public func toString() -> String {
		var output = ""
		output += "public struct \(self.name): ProtoMessage {\n\n"
		output += "\tpublic init() {}\n"
		output += "\tpublic var _unknownFields = [Int: Any]()\n"
		output += "\tpublic static let _protoFields = [\n"
		for field in self.fields {
			output += "\t\t\(field.id): ProtoFieldDescriptor(id: \(field.id), name: \"\(field.name)\","
			output += " type: .\(field.type), label: .\(field.label)),\n"
		}
		output += "\t]\n\n"
		output += "\tpublic mutating func set(name: String, value: Any?) throws {\n"
		output += "\t\tswitch name {\n"
		for field in self.fields {
			output += "\t\tcase \"\(field.name)\":\n"
			output += "\t\t\tguard value is \(field.type.type(labeled: field.label))"
			output += " else { throw ProtoError.typeMismatchError }\n"
			output += "\t\t\tself.\(field.camelName) = value as! \(field.type.type(labeled: field.label))\n"
		}
		output += "\t\tdefault: throw ProtoError.fieldNameNotFoundError\n"
		output += "\t\t}\n\t}\n\n"
		output += "\tpublic func get(name: String) throws -> Any? {\n"
		output += "\t\tswitch name {\n"
		for field in self.fields {
			output += "\t\tcase \"\(field.name)\": return self.\(field.camelName)\n"
		}
		output += "\t\tdefault: throw ProtoError.fieldNameNotFoundError\n"
		output += "\t\t}\n\t}\n\n"
		for field in self.fields {
			output += "\tpublic var \(field.camelName): \(field.type.container(labeled: field.label))\n"
		}
		return output + "}"
	}
}

public struct ProtoFileDescriptor {
	public let name: String = "" // filename
	public let syntax: String // [proto2, proto3]
	public let package: String
	public let imports: [ProtoImportDescriptor]
	public let enums: [ProtoEnumDescriptor]
	public let messages: [ProtoMessageDescriptor]
	
	public static func fromString(string: String) throws -> ProtoFileDescriptor {
		var string = string
		string.replaceAllOccurrences(matching: COMMENT_REGEX, with: "")
		
		let enums = string
			.findAllOccurrences(matching: ENUM_REGEX, all: true)
			.map { try? ProtoEnumDescriptor.fromString(string: $0) }
			.flatMap { $0 }
		
		let messages = string
			.findAllOccurrences(matching: MESSAGE_REGEX, all: true)
			.map { try? ProtoMessageDescriptor.fromString(string: $0) }
			.flatMap { $0 }
		
		return ProtoFileDescriptor(syntax: "proto2", package: "",
		                           imports: [], enums: enums, messages: messages)
	}
	
	public func toString() -> String {
		var output = ""
		output += self.enums.map { $0.toString() + "\n\n" }.reduce("", combine: +)
		output += self.messages.map { $0.toString() + "\n\n" }.reduce("", combine: +)
		output += "let _protoMessages: [String: Initializable.Type] = [\n"
		for e in self.messages {
			output += "\t\"\(e.name)\": \(e.name).self,\n"
		}
		return output + "]"
	}
}

public func translateProtoFile(filename: String) {
	func _convert(_ file: String) -> String {
		let components = file.components(separatedBy: "/")
		let filename = components.last! + ".swift"
		return components.dropLast().joined(separator: "/") + "/" + filename
	}
	
	do {
		let content = try String(contentsOfFile: Process.arguments[1], encoding: NSUTF8StringEncoding)
		let output = try! ProtoFileDescriptor.fromString(string: content).toString()
		
		do {
			let outputFilename = _convert(filename)
			try output.write(toFile: outputFilename, atomically: true, encoding: NSUTF8StringEncoding)
			print("\(filename) written successfully.")
			
		} catch {
			print("Could not write output file \(filename).")
		}
	} catch {
		print("Could not read input file \(filename).")
	}
}
