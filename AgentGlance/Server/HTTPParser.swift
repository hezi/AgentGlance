import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

enum HTTPParser {
    /// Parse a raw HTTP/1.1 request from accumulated data.
    /// Returns nil if the request is incomplete (need more data).
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = findHeaderEnd(in: data) else { return nil }

        let headerData = data[data.startIndex..<headerEnd]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEnd + 4 // skip \r\n\r\n
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0

        guard data.count >= bodyStart + contentLength else { return nil } // incomplete body

        let body = data[bodyStart..<(bodyStart + contentLength)]

        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body))
    }

    /// Build a minimal HTTP 200 response
    static func okResponse(body: String = "{}") -> Data {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        return Data(response.utf8)
    }

    private static func findHeaderEnd(in data: Data) -> Int? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) {
            if bytes[i] == separator[0] &&
               bytes[i+1] == separator[1] &&
               bytes[i+2] == separator[2] &&
               bytes[i+3] == separator[3] {
                return i
            }
        }
        return nil
    }
}
