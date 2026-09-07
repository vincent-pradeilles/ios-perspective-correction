import Foundation

struct PhotoroomClient: Sendable {
    private let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    // Same endpoint, header, and multipart fields as the supplied demo's createSegmentationMask.
    static func maskRequest(image: Data, apiKey: String, boundary: String = "CardStraight-\(UUID().uuidString)") throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw PhotoroomError.missingKey }
        var request = URLRequest(url: URL(string: "https://sdk.photoroom.com/v1/segment")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("image/png", forHTTPHeaderField: "Accept")
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image_file\"; filename=\"card.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
        body.append(image)
        append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"channels\"\r\n\r\nalpha\r\n")
        append("--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    func segmentationMask(image: Data, apiKey: String) async throws -> Data {
        let request = try Self.maskRequest(image: image, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PhotoroomError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw Self.responseError(status: response.statusCode)
        }
        guard !data.isEmpty else { throw PhotoroomError.invalidResponse }
        return data
    }

    static func responseError(status: Int) -> PhotoroomError {
        switch status {
        case 401, 403: .invalidKey
        case 402: .credits
        case 429: .rateLimited
        default: .server(status)
        }
    }
}

enum PhotoroomError: LocalizedError {
    case missingKey, invalidKey, credits, rateLimited, invalidResponse, server(Int)
    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Photoroom API key in Settings to process a card."
        case .invalidKey: "Photoroom rejected the API key. Check your key and API access in Settings."
        case .credits: "Your Photoroom account needs API credits to process this image."
        case .rateLimited: "Photoroom is receiving too many requests. Wait a moment, then try again."
        case .invalidResponse: "Photoroom didn’t return a usable mask. Please try again."
        case .server(let status): "Photoroom couldn’t process this image (HTTP \(status)). Please try again."
        }
    }
}
