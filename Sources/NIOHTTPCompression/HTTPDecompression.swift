//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2019-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CNIOExtrasZlib
import NIOCore

/// Namespace for decompression code.
public enum NIOHTTPDecompression: Sendable {
    /// Specifies how to limit decompression inflation.
    public struct DecompressionLimit: Sendable {
        private enum Limit {
            case none
            case size(Int)
            case ratio(Int)
        }

        private var limit: Limit

        /// No limit will be set.
        /// - warning: Setting `limit` to `.none` leaves you vulnerable to denial of service attacks.
        public static let none = DecompressionLimit(limit: .none)
        /// Limit will be set on the request body size.
        public static func size(_ value: Int) -> DecompressionLimit { DecompressionLimit(limit: .size(value)) }
        /// Limit will be set on a ratio between compressed body size and decompressed result.
        public static func ratio(_ value: Int) -> DecompressionLimit { DecompressionLimit(limit: .ratio(value)) }

        func exceeded(compressed: Int, decompressed: Int) -> Bool {
            switch self.limit {
            case .none:
                return false
            case .size(let allowed):
                return decompressed > allowed
            case .ratio(let ratio):
                return decompressed > compressed * ratio
            }
        }
    }

    /// Error types for ``NIOHTTPCompression``
    public enum DecompressionError: Error, Equatable {
        /// The set ``NIOHTTPDecompression/DecompressionLimit`` has been exceeded
        case limit
        /// An error occured when inflating.  Error code is included to aid diagnosis.
        case inflationError(Int)
        /// Decoder could not be initialised.  Error code is included to aid diagnosis.
        case initializationError(Int)
    }

    public struct ExtraDecompressionError: Error, Hashable, CustomStringConvertible {
        private var backing: Backing

        private enum Backing {
            case invalidTrailingData
            case truncatedData
        }

        private init(_ backing: Backing) {
            self.backing = backing
        }

        /// Decompression completed but there was invalid trailing data behind the compressed data.
        public static let invalidTrailingData = Self(.invalidTrailingData)

        /// The decompressed data was incorrectly truncated.
        public static let truncatedData = Self(.truncatedData)

        public var description: String {
            String(describing: self.backing)
        }
    }

    enum CompressionAlgorithm: String {
        case gzip
        case deflate

        init?(header: String?) {
            switch header {
            case .some("gzip"):
                self = .gzip
            case .some("deflate"):
                self = .deflate
            default:
                return nil
            }
        }
    }

    struct Decompressor {
        /// `15` is the base two logarithm of the maximum window size (the size of the history buffer). It should be in the range 8..15 for this version of the library.
        /// `32` enables automatic detection of gzip or zlib compression format with automatic header detection.
        ///
        /// Documentation from https://www.zlib.net/manual.html:
        /// The windowBits parameter is the base two logarithm of the maximum window size (the size of the history buffer).
        /// It should be in the range 8..15 for this version of the library.
        /// The default value is 15 if inflateInit is used instead.
        /// windowBits must be greater than or equal to the windowBits value provided to deflateInit2() while compressing,
        /// or it must be equal to 15 if deflateInit2() was not used.
        /// If a compressed stream with a larger window size is given as input,
        /// inflate() will return with the error code Z_DATA_ERROR instead of trying to allocate a larger window.
        /// windowBits can also be zero to request that inflate use the window size in the zlib header of the compressed stream.
        /// windowBits can also be –8..–15 for raw inflate.
        /// In this case, -windowBits determines the window size.
        /// inflate() will then process raw deflate data, not looking for a zlib or gzip header, not generating a check value,
        /// and not looking for any check values for comparison at the end of the stream.
        /// This is for use with other formats that use the deflate compressed data format such as zip.
        /// Those formats provide their own check values.
        /// If a custom format is developed using the raw deflate format for compressed data,
        /// it is recommended that a check value such as an Adler-32 or a CRC-32 be applied to the uncompressed data as is done in the zlib,
        /// gzip, and zip formats. For most applications, the zlib format should be used as is.
        /// Note that comments above on the use in deflateInit2() applies to the magnitude of windowBits.
        /// windowBits can also be greater than 15 for optional gzip decoding.
        /// Add 32 to windowBits to enable zlib and gzip decoding with automatic header detection,
        /// or add 16 to decode only the gzip format (the zlib format will return a Z_DATA_ERROR).
        /// If a gzip stream is being decoded, strm->adler is a CRC-32 instead of an Adler-32.
        /// Unlike the gunzip utility and gzread() (see below), inflate() will not automatically decode concatenated gzip members.
        /// inflate() will return Z_STREAM_END at the end of the gzip member.
        /// The state would need to be reset to continue decoding a subsequent gzip member.
        /// This must be done if there is more data after a gzip member, in order for the decompression to be compliant with the gzip standard (RFC 1952).
        static let windowBitsWithAutomaticCompressionFormatDetection: Int32 = 15 + 32

        private let limit: NIOHTTPDecompression.DecompressionLimit
        private var stream = z_stream()
        private var inflated = 0

        init(limit: NIOHTTPDecompression.DecompressionLimit) {
            self.limit = limit
        }

        mutating func decompress(
            part: inout ByteBuffer,
            buffer: inout ByteBuffer,
            compressedLength: Int
        ) throws -> InflateResult {
            let result = try self.stream.inflatePart(input: &part, output: &buffer)
            self.inflated += result.written

            if self.limit.exceeded(compressed: compressedLength, decompressed: self.inflated) {
                throw NIOHTTPDecompression.DecompressionError.limit
            }

            return result
        }

        mutating func initializeDecoder() throws {
            self.stream.zalloc = nil
            self.stream.zfree = nil
            self.stream.opaque = nil
            self.inflated = 0

            let rc = CNIOExtrasZlib_inflateInit2(&self.stream, Self.windowBitsWithAutomaticCompressionFormatDetection)
            guard rc == Z_OK else {
                throw NIOHTTPDecompression.DecompressionError.initializationError(Int(rc))
            }
        }

        mutating func deinitializeDecoder() {
            inflateEnd(&self.stream)
        }
    }
}

extension z_stream {
    mutating func inflatePart(input: inout ByteBuffer, output: inout ByteBuffer) throws -> InflateResult {
        let minimumCapacity = input.readableBytes * 2
        var inflateResult = InflateResult(written: 0, complete: false)

        try input.readWithUnsafeMutableReadableBytes { pointer in
            self.avail_in = UInt32(pointer.count)
            self.next_in = CNIOExtrasZlib_voidPtr_to_BytefPtr(pointer.baseAddress!)

            defer {
                self.avail_in = 0
                self.next_in = nil
                self.avail_out = 0
                self.next_out = nil
            }

            inflateResult = try self.inflatePart(to: &output, minimumCapacity: minimumCapacity)

            return pointer.count - Int(self.avail_in)
        }
        return inflateResult
    }

    private mutating func inflatePart(to buffer: inout ByteBuffer, minimumCapacity: Int) throws -> InflateResult {
        var rc = Z_OK

        let written = try buffer.writeWithUnsafeMutableBytes(minimumWritableBytes: minimumCapacity) { pointer in
            self.avail_out = UInt32(pointer.count)
            self.next_out = CNIOExtrasZlib_voidPtr_to_BytefPtr(pointer.baseAddress!)

            rc = inflate(&self, Z_NO_FLUSH)
            guard rc == Z_OK || rc == Z_STREAM_END else {
                throw NIOHTTPDecompression.DecompressionError.inflationError(Int(rc))
            }

            return pointer.count - Int(self.avail_out)
        }

        return InflateResult(written: written, complete: rc == Z_STREAM_END)
    }
}

struct InflateResult {
    var written: Int

    var complete: Bool
}
