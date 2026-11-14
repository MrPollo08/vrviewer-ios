import Foundation

enum SocketError: LocalizedError {
    case create(Int32)
    case resolve(String)
    case bind(UInt16, Int32)
    case connect(String, UInt16)
    case timeout

    var errorDescription: String? {
        switch self {
        case .create(let code):
            return "No se pudo crear el socket (errno \(code))"
        case .resolve(let host):
            return "IP/host no encontrado: \(host)"
        case .bind(let port, let code):
            return "No se pudo abrir el puerto UDP \(port) (errno \(code))"
        case .connect(let host, let port):
            return "No se pudo conectar a \(host):\(port)"
        case .timeout:
            return "La PC no respondió (timeout)"
        }
    }
}

/// Socket UDP fino sobre BSD sockets (mismo modelo que el Android).
final class UDPSocket {
    private var fd: Int32
    private let lock = NSLock()
    private var closed = false

    init() throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 {
            throw SocketError.create(errno)
        }
    }

    deinit {
        close()
    }

    /// Resuelve host:puerto a sockaddr_in (IPv4).
    static func address(host: String, port: UInt16) throws -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        if inet_pton(AF_INET, host, &addr.sin_addr) == 1 {
            return addr
        }

        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let info = result else {
            throw SocketError.resolve(host)
        }
        defer { freeaddrinfo(result) }

        guard let sa = info.pointee.ai_addr else {
            throw SocketError.resolve(host)
        }
        var out = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        out.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        out.sin_family = sa_family_t(AF_INET)
        out.sin_port = port.bigEndian
        return out
    }

    func setReceiveTimeout(_ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func setBroadcast(_ enabled: Bool) {
        var value: Int32 = enabled ? 1 : 0
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    func bind(port: UInt16) throws {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = 0

        let status = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if status != 0 {
            throw SocketError.bind(port, errno)
        }
    }

    func send(_ bytes: [UInt8], to addr: sockaddr_in) {
        var target = addr
        _ = withUnsafePointer(to: &target) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bytes.withUnsafeBytes { buffer in
                    sendto(fd, buffer.baseAddress, bytes.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func send(_ data: Data, to addr: sockaddr_in) {
        send([UInt8](data), to: addr)
    }

    /// Devuelve nil si el socket se cerró o expiró el timeout.
    func receive(maxLength: Int = 1024) -> Data? {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        let count = recv(fd, &buffer, maxLength, 0)
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
    }

    /// Igual que `receive` pero además devuelve el IP del remitente.
    func receiveFrom(maxLength: Int = 1024) -> (data: Data, ip: String)? {
        var buffer = [UInt8](repeating: 0, count: maxLength)
        var sender = sockaddr_storage()
        var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)

        let count = withUnsafeMutablePointer(to: &sender) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, &buffer, maxLength, 0, sa, &senderLength)
            }
        }
        guard count > 0 else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &sender) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, senderLength, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        let ip = result == 0 ? String(cString: host) : ""
        return (Data(buffer[0..<count]), ip)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// Socket TCP bloqueante, usado por el stream de video y el de audio.
final class TCPSocket {
    private var fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(host: String, port: UInt16, connectTimeout: TimeInterval = 5) throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 {
            throw SocketError.create(errno)
        }

        var addr = try UDPSocket.address(host: host, port: port)

        var tv = timeval(tv_sec: Int(connectTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let status = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if status != 0 {
            Darwin.close(fd)
            fd = -1
            throw SocketError.connect(host, port)
        }

        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        var rcvBuf: Int32 = 2 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
    }

    /// Lee exactamente `count` bytes (bloqueante).
    func readExact(_ count: Int) throws -> Data {
        var result = Data(capacity: count)
        var chunk = [UInt8](repeating: 0, count: min(max(count, 1), 65536))
        var remaining = count

        while remaining > 0 {
            let want = min(remaining, chunk.count)
            let read = chunk.withUnsafeMutableBytes { buffer -> Int in
                recv(fd, buffer.baseAddress, want, 0)
            }
            if read <= 0 {
                throw SocketError.timeout
            }
            result.append(contentsOf: chunk[0..<read])
            remaining -= read
        }
        return result
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            closed = true
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }
}
