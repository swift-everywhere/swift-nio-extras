//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore

/// ``RequestResponseHandler`` receives a `Request` alongside an `EventLoopPromise<Response>` from the `Channel`'s
/// outbound side. It will fulfil the promise with the `Response` once it's received from the `Channel`'s inbound
/// side.
///
/// ``RequestResponseHandler`` does support pipelining `Request`s and it will send them pipelined further down the
/// `Channel`. Should ``RequestResponseHandler`` receive an error from the `Channel`, it will fail all promises meant for
/// the outstanding `Response`s and close the `Channel`. All requests enqueued after an error occurred will be immediately
/// failed with the first error the channel received.
///
/// ``RequestResponseHandler`` requires that the `Response`s arrive on `Channel` in the same order as the `Request`s
/// were submitted.
public final class RequestResponseHandler<Request, Response>: ChannelDuplexHandler {
    /// `Response` is the type this class expects to receive inbound.
    public typealias InboundIn = Response
    /// Don't expect to pass anything on in-bound.
    public typealias InboundOut = Never
    /// Type this class expect to receive in an outbound direction.
    public typealias OutboundIn = (Request, EventLoopPromise<Response>)
    /// Type this class passes out.
    public typealias OutboundOut = Request

    private enum State {
        case operational
        case error(Error)

        var isOperational: Bool {
            switch self {
            case .operational:
                return true
            case .error:
                return false
            }
        }
    }

    private var state: State = .operational
    private var promiseBuffer: CircularBuffer<EventLoopPromise<Response>>

    /// Create a new ``RequestResponseHandler``.
    ///
    /// - parameters:
    ///    - initialBufferCapacity: ``RequestResponseHandler`` saves the promises for all outstanding responses in a
    ///          buffer. `initialBufferCapacity` is the initial capacity for this buffer. You usually do not need to set
    ///          this parameter unless you intend to pipeline very deeply and don't want the buffer to resize.
    public init(initialBufferCapacity: Int = 4) {
        self.promiseBuffer = CircularBuffer(initialCapacity: initialBufferCapacity)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        switch self.state {
        case .error:
            // We failed any outstanding promises when we entered the error state and will fail any
            // new promises in write.
            assert(self.promiseBuffer.count == 0)
        case .operational:
            let promiseBuffer = self.promiseBuffer
            self.promiseBuffer.removeAll()
            for promise in promiseBuffer {
                promise.fail(NIOExtrasErrors.ClosedBeforeReceivingResponse())
            }
        }
        context.fireChannelInactive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard self.state.isOperational else {
            // we're in an error state, ignore further responses
            assert(self.promiseBuffer.count == 0)
            return
        }

        let response = self.unwrapInboundIn(data)
        let promise = self.promiseBuffer.removeFirst()

        // If the event loop of the promise is the same as the context then there's no
        // change in isolation. Otherwise transfer the response onto the correct event-loop
        // before succeeding the promise.
        if promise.futureResult.eventLoop === context.eventLoop {
            promise.assumeIsolatedUnsafeUnchecked().succeed(response)
        } else {
            let unsafeTransfer = UnsafeTransfer(response)
            promise.futureResult.eventLoop.execute {
                let response = unsafeTransfer.wrappedValue
                promise.assumeIsolatedUnsafeUnchecked().succeed(response)
            }
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard self.state.isOperational else {
            assert(self.promiseBuffer.count == 0)
            return
        }
        self.state = .error(error)
        let promiseBuffer = self.promiseBuffer
        self.promiseBuffer.removeAll()
        context.close(promise: nil)
        for promise in promiseBuffer {
            promise.fail(error)
        }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let (request, responsePromise) = self.unwrapOutboundIn(data)
        switch self.state {
        case .error(let error):
            assert(self.promiseBuffer.count == 0)
            responsePromise.fail(error)
            promise?.fail(error)
        case .operational:
            self.promiseBuffer.append(responsePromise)
            context.write(self.wrapOutboundOut(request), promise: promise)
        }
    }
}

@available(*, unavailable)
extension RequestResponseHandler: Sendable {}
