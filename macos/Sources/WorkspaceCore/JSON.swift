import Foundation

public struct WorkspaceError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct JSONField: Equatable {
    public var name: String
    public var value: JSONValue

    public init(_ name: String, _ value: JSONValue) {
        self.name = name
        self.value = value
    }
}

public indirect enum JSONValue {
    case object([JSONField])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

extension JSONValue: Equatable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case let (.object(left), .object(right)):
            return left == right
        case let (.array(left), .array(right)):
            return left == right
        case let (.string(left), .string(right)):
            return left == right
        case let (.number(left), .number(right)):
            return left == right
        case let (.bool(left), .bool(right)):
            return left == right
        case (.null, .null):
            return true
        default:
            return false
        }
    }

    public var object: [JSONField]? {
        if case let .object(pairs) = self { return pairs }
        return nil
    }

    public var array: [JSONValue]? {
        if case let .array(items) = self { return items }
        return nil
    }

    public var string: String? {
        if case let .string(value) = self { return value }
        return nil
    }
}

public func parseJSON(_ text: String) throws -> JSONValue {
    var parser = JSONParser(text)
    let value = try parser.parseValue()
    try parser.skipIgnorables()
    try parser.ensureEnd()
    return value
}

public func renderJSON(_ value: JSONValue) -> String {
    render(value, level: 0)
}

private func render(_ value: JSONValue, level: Int) -> String {
    switch value {
    case let .object(fields):
        if fields.isEmpty { return "{}" }
        let lines = fields.map { field in
            "\(tabs(level + 1))\(encodeJSONString(field.name)): \(render(field.value, level: level + 1))"
        }
        return "{\n\(lines.joined(separator: ",\n"))\n\(tabs(level))}"
    case let .array(items):
        if items.isEmpty { return "[]" }
        let lines = items.map { item in
            "\(tabs(level + 1))\(render(item, level: level + 1))"
        }
        return "[\n\(lines.joined(separator: ",\n"))\n\(tabs(level))]"
    case let .string(text):
        return encodeJSONString(text)
    case let .number(literal):
        return literal
    case let .bool(flag):
        return flag ? "true" : "false"
    case .null:
        return "null"
    }
}

private func tabs(_ level: Int) -> String {
    String(repeating: "\t", count: max(0, level))
}

private func encodeJSONString(_ value: String) -> String {
    var encoded = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22:
            encoded += "\\\""
        case 0x5C:
            encoded += "\\\\"
        case 0x08:
            encoded += "\\b"
        case 0x0C:
            encoded += "\\f"
        case 0x0A:
            encoded += "\\n"
        case 0x0D:
            encoded += "\\r"
        case 0x09:
            encoded += "\\t"
        case 0x00...0x1F:
            encoded += String(format: "\\u%04X", scalar.value)
        default:
            encoded.unicodeScalars.append(scalar)
        }
    }
    encoded += "\""
    return encoded
}

private struct JSONParser {
    private let text: String
    private var index: String.Index

    init(_ text: String) {
        var source = text
        if source.hasPrefix("\u{FEFF}") {
            source.removeFirst()
        }
        self.text = source
        self.index = source.startIndex
    }

    mutating func parseValue() throws -> JSONValue {
        try skipIgnorables()
        guard let character = peek() else { throw fail("缺少內容") }
        switch character {
        case "{":
            return try parseObject()
        case "[":
            return try parseArray()
        case "\"":
            return .string(try parseString())
        case "t", "f", "n":
            return try parseLiteral()
        case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return try parseNumber()
        default:
            throw fail("無法辨識的內容")
        }
    }

    mutating func skipIgnorables() throws {
        while true {
            while let character = peek(), character == " " || character == "\t" || character == "\n" || character == "\r" {
                advance()
            }
            guard peek() == "/" else { return }
            let marker = peekAhead(1)
            if marker == "/" {
                advance()
                advance()
                while let character = peek(), character != "\n" {
                    advance()
                }
                continue
            }
            if marker == "*" {
                advance()
                advance()
                var closed = false
                while index < text.endIndex {
                    if peek() == "*" && peekAhead(1) == "/" {
                        advance()
                        advance()
                        closed = true
                        break
                    }
                    advance()
                }
                if !closed { throw fail("註解沒有結束") }
                continue
            }
            return
        }
    }

    mutating func ensureEnd() throws {
        guard index >= text.endIndex else { throw fail("檔案結尾還有多餘內容") }
    }

    private mutating func parseObject() throws -> JSONValue {
        try expect("{")
        try skipIgnorables()
        var fields: [JSONField] = []
        if peek() == "}" {
            advance()
            return .object(fields)
        }
        while true {
            guard peek() == "\"" else { throw fail("物件的鍵必須是字串") }
            let key = try parseString()
            try skipIgnorables()
            try expect(":")
            try skipIgnorables()
            fields.append(JSONField(key, try parseValue()))
            try skipIgnorables()
            if peek() == "," {
                advance()
                try skipIgnorables()
                if peek() == "}" {
                    advance()
                    return .object(fields)
                }
                continue
            }
            if peek() == "}" {
                advance()
                return .object(fields)
            }
            throw fail("物件格式不正確")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try expect("[")
        try skipIgnorables()
        var items: [JSONValue] = []
        if peek() == "]" {
            advance()
            return .array(items)
        }
        while true {
            items.append(try parseValue())
            try skipIgnorables()
            if peek() == "," {
                advance()
                try skipIgnorables()
                if peek() == "]" {
                    advance()
                    return .array(items)
                }
                continue
            }
            if peek() == "]" {
                advance()
                return .array(items)
            }
            throw fail("陣列格式不正確")
        }
    }

    private mutating func parseString() throws -> String {
        try expect("\"")
        var value = ""
        while let character = peek() {
            if character == "\"" {
                advance()
                return value
            }
            if character == "\\" {
                advance()
                value += try parseEscape()
                continue
            }
            if character == "\n" || character == "\r" {
                throw fail("字串沒有結束")
            }
            value.append(character)
            advance()
        }
        throw fail("字串沒有結束")
    }

    private mutating func parseEscape() throws -> String {
        guard let character = pop() else { throw fail("字串結尾的反斜線無效") }
        switch character {
        case "\"": return "\""
        case "\\": return "\\"
        case "/": return "/"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "n": return "\n"
        case "r": return "\r"
        case "t": return "\t"
        case "u": return try parseUnicodeEscape()
        default: throw fail("不認識的跳脫字元")
        }
    }

    private mutating func parseUnicodeEscape() throws -> String {
        let unit = try parseHex4()
        if (0xD800...0xDBFF).contains(unit) {
            guard peek() == "\\", peekAhead(1) == "u" else { throw fail("不成對的代理字元") }
            advance()
            advance()
            let low = try parseHex4()
            guard (0xDC00...0xDFFF).contains(low) else { throw fail("不成對的代理字元") }
            let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
            guard let scalar = UnicodeScalar(combined) else { throw fail("無效的字元") }
            return String(scalar)
        }
        if (0xDC00...0xDFFF).contains(unit) { throw fail("不成對的代理字元") }
        guard let scalar = UnicodeScalar(unit) else { throw fail("無效的字元") }
        return String(scalar)
    }

    private mutating func parseHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let character = pop(), let digit = character.hexDigitValue else {
                throw fail("\\u 需要四位十六進位")
            }
            value = value * 16 + UInt32(digit)
        }
        return value
    }

    private mutating func parseLiteral() throws -> JSONValue {
        if consume("true") { return .bool(true) }
        if consume("false") { return .bool(false) }
        if consume("null") { return .null }
        throw fail("無法辨識的內容")
    }

    private mutating func parseNumber() throws -> JSONValue {
        let begin = index
        if peek() == "-" { advance() }
        guard let first = peek(), isDigit(first) else { throw fail("數字格式錯誤") }
        if first == "0" {
            advance()
        } else {
            while let character = peek(), isDigit(character) { advance() }
        }
        if peek() == "." {
            advance()
            guard let character = peek(), isDigit(character) else { throw fail("數字格式錯誤") }
            while let character = peek(), isDigit(character) { advance() }
        }
        if peek() == "e" || peek() == "E" {
            advance()
            if peek() == "+" || peek() == "-" { advance() }
            guard let character = peek(), isDigit(character) else { throw fail("數字格式錯誤") }
            while let character = peek(), isDigit(character) { advance() }
        }
        return .number(String(text[begin..<index]))
    }

    private mutating func expect(_ character: Character) throws {
        guard peek() == character else { throw fail("格式不正確") }
        advance()
    }

    private mutating func consume(_ word: String) -> Bool {
        guard text[index...].hasPrefix(word) else { return false }
        index = text.index(index, offsetBy: word.count)
        return true
    }

    private func peek() -> Character? {
        guard index < text.endIndex else { return nil }
        return text[index]
    }

    private func peekAhead(_ offset: Int) -> Character? {
        var cursor = index
        for _ in 0..<offset {
            guard cursor < text.endIndex else { return nil }
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex else { return nil }
        return text[cursor]
    }

    private mutating func pop() -> Character? {
        guard let character = peek() else { return nil }
        advance()
        return character
    }

    private mutating func advance() {
        guard index < text.endIndex else { return }
        index = text.index(after: index)
    }

    private func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private func fail(_ message: String) -> WorkspaceError {
        let prefix = text[..<index]
        let line = prefix.reduce(1) { partial, character in
            character == "\n" ? partial + 1 : partial
        }
        let column = prefix.reversed().prefix { $0 != "\n" }.count + 1
        return WorkspaceError("工作區內容不是有效的 JSON：第 \(line) 行第 \(column) 欄，\(message)")
    }
}
