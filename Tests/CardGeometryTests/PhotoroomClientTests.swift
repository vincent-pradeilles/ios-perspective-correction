import Foundation
import Testing
@testable import CardGeometry

@Test func maskRequestMatchesDemo() throws {
    let image = Data([0, 1, 2, 255])
    let request = try PhotoroomClient.maskRequest(image: image, apiKey: " test-key ", boundary: "test-boundary")
    #expect(request.url?.absoluteString == "https://sdk.photoroom.com/v1/segment")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=test-boundary")
    let expectedStart = Data("--test-boundary\r\nContent-Disposition: form-data; name=\"image_file\"; filename=\"card.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
    let expectedEnd = Data("\r\n--test-boundary\r\nContent-Disposition: form-data; name=\"channels\"\r\n\r\nalpha\r\n--test-boundary--\r\n".utf8)
    #expect(request.httpBody == expectedStart + image + expectedEnd)
}

@Test func rejectsMissingOrInvalidKeyBeforeSending() {
    for key in ["", " \n ", "key\ninjected-header", "key\rheader"] {
        #expect(throws: PhotoroomError.self) { try PhotoroomClient.maskRequest(image: Data(), apiKey: key) }
    }
}

@Test func actionableAPIErrors() {
    #expect(PhotoroomClient.responseError(status: 401).localizedDescription.contains("API key"))
    #expect(PhotoroomClient.responseError(status: 402).localizedDescription.contains("credits"))
    #expect(PhotoroomClient.responseError(status: 429).localizedDescription.contains("Wait"))
    #expect(PhotoroomClient.responseError(status: 503).localizedDescription.contains("503"))
}
