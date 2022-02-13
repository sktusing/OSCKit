//
//  OSCTcpServer.swift
//  OSCKit
//
//  Created by Sam Smallman on 10/07/2021.
//  Copyright © 2020 Sam Smallman. https://github.com/SammySmallman
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation
import CocoaAsyncSocket
import CoreOSC

/// An object that accepts connections from TCP clients and can send & receive OSCPackets to and from them.
public class OSCTcpServer: NSObject {

    /// A textual representation of this instance.
    public override var description: String {
        """
        OSCKit.OSCTcpServer(\
        interface: \(String(describing: interface)), \
        port: \(port), \
        streamFraming: \(streamFraming))
        """
    }

    /// A configuration object representing the current configurable state of the server.
    public var configuration: OSCTcpServerConfiguration {
        OSCTcpServerConfiguration(interface: interface,
                                  port: port,
                                  streamFraming: streamFraming)
    }

    /// The servers TCP socket that all new connections are accepted on.
    /// Also where all `OSCPacket`s are received from.
    private var socket: GCDAsyncSocket = GCDAsyncSocket()

    /// A `Dictionary` of client TCP sockets connected to the server.
    /// This dictionary is keyed by the sockets with the value containing the state of each client.
    private var _sockets: [GCDAsyncSocket: ClientState] = [:]

    /// An `Array` of tuples representing the host and port for each of the servers connected clients.
    public var clients: [(host: String, port: UInt16)] {
        queue.sync { _sockets.compactMap { (host: $0.value.host, port: $0.value.port) } }
    }

    /// The timeout for the read and write operations.
    /// If the timeout value is negative, the send operation will not use a timeout.
    public var timeout: TimeInterval {
        get { queue.sync { _timeout } }
        set { queue.sync { _timeout = newValue } }
    }
    
    /// Private: The timeout for the read and write operations.
    /// If the timeout value is negative, the send operation will not use a timeout.
    private var _timeout: TimeInterval = -1

    /// A boolean value that indicates whether the server is listening for new connections and OSC packets.
    public var isListening: Bool {
        get { queue.sync { _isListening } }
        set { queue.sync { _isListening = newValue } }
    }
    
    /// Private: A boolean value that indicates whether the server is listening for new connections and OSC packets.
    private var _isListening: Bool = false

    /// The interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.1.15").
    /// If the value of this is nil the server will listen on all interfaces.
    ///
    /// Setting this property will stop the server listening.
    public var interface: String? {
        didSet {
            stopListening()
        }
    }

    /// The servers local host.
    public var localHost: String? { socket.localHost }

    /// The port the server should listen for packets on.
    ///
    /// Setting this property will stop the server listening.
    public var port: UInt16 {
        didSet {
            stopListening()
        }
    }
    
    /// The stream framing all OSCPackets will be encoded and decoded with.
    ///
    /// There are two versions of OSC:
    /// - OSC 1.0 uses packet length headers.
    /// - OSC 1.1 uses the [SLIP protocol](http://www.rfc-editor.org/rfc/rfc1055.txt).
    public var streamFraming: OSCTcpStreamFraming {
        get { queue.sync { _streamFraming } }
        set { queue.sync { _streamFraming = newValue } }
    }
    
    /// Private: The stream framing all OSCPackets will be encoded and decoded with.
    ///
    /// There are two versions of OSC:
    /// - OSC 1.0 uses packet length headers.
    /// - OSC 1.1 uses the [SLIP protocol](http://www.rfc-editor.org/rfc/rfc1055.txt).
    private var _streamFraming: OSCTcpStreamFraming = .SLIP {
        didSet {
            _sockets.forEach { _sockets[$0.key]!.state = OSCTcp.SocketState() }
        }
    }

    /// The dispatch queue that the server runs and executes all delegate callbacks on.
    private let queue: DispatchQueue
    
    /// The servers delegate.
    ///
    /// The delegate must conform to the `OSCTcpServerDelegate` protocol.
    public var delegate: OSCTcpServerDelegate? {
        get { queue.sync { _delegate } }
        set { queue.sync { _delegate = newValue } }
    }

    /// Private: The servers delegate.
    private weak var _delegate: OSCTcpServerDelegate?

    /// A dictionary of `OSCPackets` keyed by the sequenced `tag` number.
    ///
    /// This allows for a reference to a sent packet when the
    /// GCDAsyncSocketDelegate method socket(_:didWriteDataWithTag:) is called.
    private var _sendingMessages: [Int: SentMessage] = [:]

    /// A sequential tag that is increased and associated with each message sent.
    ///
    /// The tag will wrap around to 0 if the maximum amount has been reached.
    /// This allows for a reference to a sent packet when the
    /// GCDAsyncSocketDelegate method socket(_:didWriteDataWithTag:) is called.
    private var _tag: Int = 0

    /// An OSC TCP Server.
    /// - Parameters:
    ///   - configuration: A configuration object that defines the behavior of a TCP server.
    ///   - delegate: The servers delegate.
    ///   - queue: The dispatch queue that the server runs and executes all delegate callbacks on.
    public init(configuration: OSCTcpServerConfiguration,
                delegate: OSCTcpServerDelegate? = nil,
                queue: DispatchQueue = .main) {
        if let configInterface = configuration.interface,
           configInterface.isEmpty == false {
            self.interface = configInterface
        } else {
            interface = nil
        }
        port = configuration.port
        self._delegate = queue.sync { delegate }
        self.queue = queue
        super.init()
        socket.setDelegate(self, delegateQueue: queue)
    }

    /// An OSC TCP Server.
    /// - Parameters:
    ///   - interface: An interface name (e.g. "en1" or "lo0"), the corresponding IP address
    ///                or nil if the server should listen on all interfaces.
    ///   - port: The port the server accept new connections and listen for packets on.
    ///   - streamFraming: The stream framing all OSCPackets will be encoded and decoded with by the server.
    ///   - delegate: The servers delegate.
    ///   - queue: The dispatch queue that the server executes all delegate callbacks on.
    public convenience init(interface: String? = nil,
                            port: UInt16,
                            streamFraming: OSCTcpStreamFraming,
                            delegate: OSCTcpServerDelegate? = nil,
                            queue: DispatchQueue = .main) {
        let configuration = OSCTcpServerConfiguration(interface: interface,
                                                      port: port,
                                                      streamFraming: streamFraming)
        self.init(configuration: configuration,
                  delegate: delegate,
                  queue: queue)
    }

    deinit {
        stopListening()
        socket.synchronouslySetDelegate(nil)
    }

    // MARK: Listening

    /// Start the server listening
    /// - Throws: An error relating to the setting up of the socket.
    ///
    /// The server will accept connections on the servers port. If an interface
    /// has been set, it will only accept connections through that interface;
    /// otherwise connections are accepted on all up and running interfaces.
    public func startListening() throws {
        if socket.delegateQueue != queue {
            socket.synchronouslySetDelegateQueue(queue)
        }
        try socket.accept(onInterface: interface, port: port)
        isListening = true
    }

    /// Stop the server listening.
    ///
    /// All currently connected clients will be disconnected and the servers socket is closed.
    public func stopListening() {
        guard isListening else { return }
        isListening = false
        queue.sync { _sockets.forEach { $0.key.disconnectAfterWriting() } }
        socket.disconnectAfterReadingAndWriting()
        socket.synchronouslySetDelegateQueue(nil)
    }

    /// Send an `OSCPacket` to all connected clients.
    /// - Parameters:
    ///  - packet: The packet to be sent, either an `OSCMessage` or `OSCBundle`.
    public func send(_ packet: OSCPacket) {
        queue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf._sockets.forEach { socket in
                strongSelf.socket.readData(withTimeout: strongSelf._timeout, tag: 0)
                strongSelf._sendingMessages[strongSelf._tag] = SentMessage(host: socket.value.host,
                                                                         port: socket.value.port,
                                                                         packet: packet)
                OSCTcp.send(packet: packet,
                            streamFraming: strongSelf._streamFraming,
                            with: socket.key,
                            timeout: strongSelf._timeout,
                            tag: strongSelf._tag)
                strongSelf._tag = strongSelf._tag == Int.max ? 0 : strongSelf._tag + 1
            }
        }
    }

    /// Send the raw data of an `OSCPacket` to all connected clients.
    /// - Parameter data: Data from an `OSCMessage` or `OSCBundle`.
    /// - Throws: An `OSCParserError` if a packet can't be parsed from the data.
    public func send(_ data: Data) throws {
        let packet = try OSCParser.packet(from: data)
        queue.async { [weak self] in
            guard let strongSelf = self else { return }
            strongSelf._sockets.forEach { socket in
                strongSelf.socket.readData(withTimeout: strongSelf._timeout, tag: 0)
                strongSelf._sendingMessages[strongSelf._tag] = SentMessage(host: socket.value.host,
                                                                         port: socket.value.port,
                                                                         packet: packet)
                OSCTcp.send(data: data,
                            streamFraming: strongSelf._streamFraming,
                            with: socket.key,
                            timeout: strongSelf._timeout,
                            tag: strongSelf._tag)
                strongSelf._tag = strongSelf._tag == Int.max ? 0 : strongSelf._tag + 1
            }
        }
    }

    /// Send an `OSCPacket` to a connected client.
    /// - Parameters:
    ///   - packet: The packet to be sent, either an `OSCMessage` or `OSCBundle`.
    ///   - host: The host of the client the packet should be sent to.
    ///   - port: The port of the client the packet should be sent to.
    public func send(_ packet: OSCPacket, to host: String, port: UInt16) {
        queue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard let socket = strongSelf._sockets.first(where: {
                $0.value.host == host && $0.value.port == port
            }) else {
                return
            }
            strongSelf.socket.readData(withTimeout: strongSelf._timeout, tag: 0)
            strongSelf._sendingMessages[strongSelf._tag] = SentMessage(host: socket.value.host,
                                                                     port: socket.value.port,
                                                                     packet: packet)
            OSCTcp.send(packet: packet,
                        streamFraming: strongSelf._streamFraming,
                        with: socket.key,
                        timeout: strongSelf._timeout,
                        tag: strongSelf._tag)
            strongSelf._tag = strongSelf._tag == Int.max ? 0 : strongSelf._tag + 1
        }
    }

    /// Send the raw data of an `OSCPacket` to a connected client.
    /// - Parameters:
    ///   - data: Data from an `OSCMessage` or `OSCBundle`.
    ///   - host: The host of the client the packet should be sent to.
    ///   - port: The port of the client the packet should be sent to.
    /// - Throws: An `OSCParserError` if a packet can't be parsed from the data.
    public func send(_ data: Data, to host: String, port: UInt16) throws {
        let packet = try OSCParser.packet(from: data)
        queue.async { [weak self] in
            guard let strongSelf = self else { return }
            guard let socket = strongSelf._sockets.first(where: {
                $0.value.host == host && $0.value.port == port
            }) else {
                return
            }
            strongSelf.socket.readData(withTimeout: strongSelf._timeout, tag: 0)
            strongSelf._sendingMessages[strongSelf._tag] = SentMessage(host: socket.value.host,
                                                                     port: socket.value.port,
                                                                     packet: packet)
            OSCTcp.send(data: data,
                        streamFraming: strongSelf._streamFraming,
                        with: socket.key,
                        timeout: strongSelf._timeout,
                        tag: strongSelf._tag)
            strongSelf._tag = strongSelf._tag == Int.max ? 0 : strongSelf._tag + 1
        }
    }

}

// MARK: - GCDAsyncSocketDelegate
extension OSCTcpServer: GCDAsyncSocketDelegate {

    public func socket(_ sock: GCDAsyncSocket,
                       didAcceptNewSocket newSocket: GCDAsyncSocket) {
        if !_isListening {
            _isListening = true
        }
        guard let host = newSocket.connectedHost else { return }
        _sockets[newSocket] = ClientState(host: host,
                                         port: newSocket.connectedPort)
        newSocket.readData(withTimeout: _timeout, tag: 0)
        _delegate?.server(self,
                         didConnectToClientWithHost: host,
                         port: newSocket.connectedPort)
    }

    public func socket(_ sock: GCDAsyncSocket,
                       didRead data: Data,
                       withTag tag: Int) {
        if !_isListening {
            _isListening = true
        }
        guard _sockets.keys.contains(sock) else { return }
        do {
            switch _streamFraming {
            case .SLIP:
                try OSCTcp.decodeSLIP(data,
                                      with: &_sockets[sock]!.state,
                                      dispatchHandler: { [weak self] packet in
                    guard let strongSelf = self,
                          let delegate = strongSelf._delegate,
                          let host = sock.connectedHost else { return }
                    delegate.server(strongSelf,
                                    didReceivePacket: packet,
                                    fromHost: host,
                                    port: sock.connectedPort)
                })
            case .PLH:
                try OSCTcp.decodePLH(data,
                                     with: &_sockets[sock]!.state.data,
                                     dispatchHandler: { [weak self] packet in
                    guard let strongSelf = self,
                          let delegate = strongSelf._delegate,
                          let host = sock.connectedHost else { return }
                    delegate.server(strongSelf,
                                    didReceivePacket: packet,
                                    fromHost: host,
                                    port: sock.connectedPort)
                })
            }
            sock.readData(withTimeout: _timeout,
                          tag: 0)
        } catch {
            _delegate?.server(self,
                             didReadData: data,
                             with: error)
        }
    }

    public func socket(_ sock: GCDAsyncSocket,
                       didWriteDataWithTag tag: Int) {
        if !_isListening {
            _isListening = true
        }
        guard let sentMessage = _sendingMessages[tag] else { return }
        _sendingMessages[tag] = nil
        _delegate?.server(self,
                         didSendPacket: sentMessage.packet,
                         toClientWithHost: sentMessage.host,
                         port: sentMessage.port)

    }

    public func socketDidDisconnect(_ sock: GCDAsyncSocket,
                                    withError error: Error?) {
        if sock != socket {
            if !_isListening {
                _isListening = true
            }
            guard let host = _sockets[sock]?.host,
                  let port = _sockets[sock]?.port else { return }
            _sockets[sock] = nil
            _delegate?.server(self,
                             didDisconnectFromClientWithHost: host,
                             port: port)
        } else {
            _delegate?.server(self,
                             socketDidCloseWithError: error)
            _sockets.removeAll()
            _sendingMessages.removeAll()
            _tag = 0
            _isListening = false
        }
    }

}

extension OSCTcpServer {

    /// An object that contains the state of a client connection.
    private struct ClientState {

        /// The host of the client.
        let host: String

        /// The port of the client.
        let port: UInt16

        /// An object that contains the current state of the received data from a clients socket.
        var state: OSCTcp.SocketState

        /// An object that contains the state of a client connection.
        /// - Parameters:
        ///   - host: The host of the client.
        ///   - port: The port of the client.
        ///   - state: An object that contains the current state of the received data from a clients socket.
        init(host: String,
             port: UInt16,
             state: OSCTcp.SocketState = .init()) {
            self.host = host
            self.port = port
            self.state = state
        }

    }
}

extension OSCTcpServer {

    /// An object that represents a packet sent to a client.
    private struct SentMessage {

        /// The host of the client the message was sent to.
        let host: String

        /// The port of the client the message was sent to.
        let port: UInt16

        /// The message that was sent to the client.
        let packet: OSCPacket

    }
}
