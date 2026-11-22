import Foundation

/// The other provider: any service with an OpenAI-style Chat Completions API (OpenAI, Google Gemini,
/// OpenRouter, …). Podium keeps its conversations in the Messages API's shape; this translates a
/// request into a chat-completions request, streams the answer, and translates it back, so the panel,
/// the prep-notes tool and prep mode work unchanged.
enum OpenAICompatible {
    static func stream(connection: AIConnection, body: [String: Any], timeout: TimeInterval,
                       onText: @escaping @MainActor (String) -> Void) async -> AssistantStore.StreamResult {
        let name = connection.name
        guard let url = URL(string: connection.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                             + "/chat/completions"), url.scheme == "https" else {
            return .failure("The provider address isn't a valid https address. Check it in the key settings.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(connection.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        guard let data = try? JSONSerialization.data(withJSONObject: translate(body, model: connection.otherModel)) else {
            return .failure("Couldn't prepare the request.")
        }
        request.httpBody = data

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                var raw = Data()
                for try await byte in bytes {
                    raw.append(byte)
                    if raw.count > 64_000 { break }
                }
                return .failure(friendlyError(status: status, body: raw, name: name))
            }

            var visible = ""
            var finish: String?
            // Tool calls arrive in pieces, keyed by their index.
            var calls: [Int: (id: String, name: String, arguments: String)] = [:]
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
                if let error = json["error"] as? [String: Any] {
                    return .failure("\(name) returned an error: \(error["message"] as? String ?? "unknown error")")
                }
                guard let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
                if let reason = choice["finish_reason"] as? String { finish = reason }
                guard let delta = choice["delta"] as? [String: Any] else { continue }
                if let piece = delta["content"] as? String, !piece.isEmpty {
                    visible += piece
                    await onText(visible)
                }
                for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = call["index"] as? Int ?? 0
                    var entry = calls[index] ?? ("", "", "")
                    if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                    if let function = call["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty { entry.name = name }
                        if let arguments = function["arguments"] as? String { entry.arguments += arguments }
                    }
                    calls[index] = entry
                }
            }
            if Task.isCancelled { return .cancelled }

            // Back into the Messages API's shape: a text block, then any tool calls.
            var blocks: [[String: Any]] = []
            if !visible.isEmpty { blocks.append(["type": "text", "text": visible]) }
            for index in calls.keys.sorted() {
                guard let call = calls[index] else { continue }
                let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
                blocks.append(["type": "tool_use", "id": call.id.isEmpty ? "call_\(index)" : call.id,
                               "name": call.name, "input": input])
            }
            let stopReason: String? = switch finish {
            case "tool_calls", "function_call": "tool_use"
            case "length": "max_tokens"
            case "content_filter": "refusal"
            default: calls.isEmpty ? "end_turn" : "tool_use"
            }
            if stopReason == "refusal" { return .failure("\(name) declined to answer this one. Try rephrasing the question.") }
            return .success(blocks: blocks, visible: visible, stopReason: stopReason)
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost].contains(error.code) {
            return .failure("No connection to \(name). Check the iPad's Wi-Fi and try again.")
        } catch {
            return .failure("Something went wrong talking to \(name): \(error.localizedDescription)")
        }
    }

    // MARK: Translation

    /// Messages API request → Chat Completions request.
    static func translate(_ body: [String: Any], model: String) -> [String: Any] {
        var messages: [[String: Any]] = []
        // System: a string, or text blocks (cache hints dropped).
        let system: String
        if let text = body["system"] as? String {
            system = text
        } else {
            system = (body["system"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        }
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }

        for message in body["messages"] as? [[String: Any]] ?? [] {
            let role = message["role"] as? String ?? "user"
            let blocks: [[String: Any]]
            if let text = message["content"] as? String {
                blocks = [["type": "text", "text": text]]
            } else {
                blocks = message["content"] as? [[String: Any]] ?? []
            }
            if role == "assistant" {
                let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                let calls: [[String: Any]] = blocks.filter { $0["type"] as? String == "tool_use" }.map { block in
                    let input = block["input"] ?? [:]
                    let arguments = (try? JSONSerialization.data(withJSONObject: input)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    return ["id": block["id"] as? String ?? "", "type": "function",
                            "function": ["name": block["name"] as? String ?? "", "arguments": arguments]]
                }
                var out: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
                if !calls.isEmpty { out["tool_calls"] = calls }
                messages.append(out)
            } else {
                // Tool results become "tool" messages (right after the assistant's calls); the rest is the user's turn.
                var parts: [[String: Any]] = []
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        parts.append(["type": "text", "text": block["text"] as? String ?? ""])
                    case "image":
                        if let source = block["source"] as? [String: Any], let data = source["data"] as? String {
                            let media = source["media_type"] as? String ?? "image/jpeg"
                            parts.append(["type": "image_url", "image_url": ["url": "data:\(media);base64,\(data)"]])
                        }
                    case "tool_result":
                        let content: String
                        if let text = block["content"] as? String {
                            content = text
                        } else {
                            content = (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
                        }
                        messages.append(["role": "tool", "tool_call_id": block["tool_use_id"] as? String ?? "", "content": content])
                    default:
                        break
                    }
                }
                if !parts.isEmpty { messages.append(["role": "user", "content": parts]) }
            }
        }

        var out: [String: Any] = ["model": model, "stream": true, "messages": messages]
        if let tools = body["tools"] as? [[String: Any]], !tools.isEmpty {
            out["tools"] = tools.map { tool in
                ["type": "function",
                 "function": ["name": tool["name"] ?? "", "description": tool["description"] ?? "",
                              "parameters": tool["input_schema"] ?? ["type": "object"]]] as [String: Any]
            }
        }
        // Prep mode asks for JSON in a fixed shape.
        if let config = body["output_config"] as? [String: Any], let format = config["format"] as? [String: Any],
           let schema = format["schema"] {
            out["response_format"] = ["type": "json_schema", "json_schema": ["name": "prep_notes", "schema": schema]]
        }
        return out
    }

    private static func friendlyError(status: Int, body: Data, name: String) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = (json?["error"] as? [String: Any]) ?? (json?.first?.value as? [String: Any])
        let message = (error?["message"] as? String) ?? String(decoding: body.prefix(300), as: UTF8.self)
        switch status {
        case 401: return "\(name) didn't accept that API key. Check it in the key settings."
        case 403: return "This API key isn't allowed to use that model on \(name). Check the model name or the key's permissions."
        case 404: return "\(name) doesn't know that model or address. Check the model name and address in the key settings. (\(message))"
        case 429: return "\(name): too many requests or out of credit (HTTP 429). \(message)"
        default: return "\(name) returned an error (HTTP \(status)): \(message)"
        }
    }
}
