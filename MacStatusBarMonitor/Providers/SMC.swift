import Foundation
import IOKit

// =============================================================================
// V2 SENSOR SUPPORT — SMC ACCESS (read-only)
//
// This file talks to the System Management Controller through the AppleSMC
// IOKit service. Reading sensor keys this way requires NO sudo, NO helper
// tool, and NO special entitlements — but the user-client interface is not a
// documented public API. Apple could change it in a future macOS release.
//
// That limitation is deliberately contained here and in
// HardwareSensorProvider.swift: every call fails soft (returns nil), so V1
// features are completely unaffected if the SMC can't be opened or a key
// doesn't exist. The UI shows "Unavailable" in that case.
// =============================================================================

final class SMCClient {

    // MARK: - Raw kernel structures
    // Layout must match the kernel's 80-byte SMCParamStruct exactly.
    // init?() verifies the size at runtime and refuses to run if it differs.

    private struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        // C pads this struct to 12 bytes (sizeof includes trailing padding);
        // Swift doesn't, so pad explicitly to keep the parent layout identical.
        var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
                   (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Command: UInt8 {
        case readKey = 5
        case keyFromIndex = 8
        case keyInfo = 9
    }

    /// Selector for the SMC user client's single "handle event" method.
    private static let handleYPCEvent: UInt32 = 2

    private let connection: io_connect_t

    // MARK: - Lifecycle

    init?() {
        // If Swift ever lays this struct out differently than the kernel
        // expects, bail out instead of sending garbage.
        guard MemoryLayout<ParamStruct>.size == 80 else { return nil }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        var connect: io_connect_t = IO_OBJECT_NULL
        let openResult = IOServiceOpen(service, mach_task_self_, 0, &connect)
        IOObjectRelease(service)
        guard openResult == kIOReturnSuccess, connect != IO_OBJECT_NULL else { return nil }
        connection = connect
    }

    deinit {
        IOServiceClose(connection)
    }

    // MARK: - Public interface

    struct KeyData {
        let type: String
        let bytes: [UInt8]
    }

    /// All key names the SMC reports. Used once for sensor discovery.
    func allKeys() -> [String] {
        guard let count = readDouble(key: "#KEY").map(Int.init), count > 0, count < 10_000 else {
            return []
        }
        var keys: [String] = []
        keys.reserveCapacity(count)
        for index in 0..<count {
            var input = ParamStruct()
            input.data8 = Command.keyFromIndex.rawValue
            input.data32 = UInt32(index)
            guard let output = call(input), output.key != 0 else { continue }
            keys.append(Self.fourCC(output.key))
        }
        return keys
    }

    /// Raw bytes and type for one key, or nil if missing/unreadable.
    func read(key: String) -> KeyData? {
        guard let keyCode = Self.fourCC(key) else { return nil }

        var infoInput = ParamStruct()
        infoInput.key = keyCode
        infoInput.data8 = Command.keyInfo.rawValue
        guard let info = call(infoInput) else { return nil }
        let size = Int(info.keyInfo.dataSize)
        guard size > 0, size <= 32 else { return nil }

        var readInput = ParamStruct()
        readInput.key = keyCode
        readInput.keyInfo.dataSize = info.keyInfo.dataSize
        readInput.data8 = Command.readKey.rawValue
        guard let output = call(readInput) else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return KeyData(type: Self.fourCC(info.keyInfo.dataType), bytes: bytes)
    }

    /// One key decoded to a Double based on its SMC data type.
    func readDouble(key: String) -> Double? {
        read(key: key).flatMap(Self.decode)
    }

    // MARK: - Decoding

    /// Decodes the SMC types used by temperature/fan/count keys.
    static func decode(_ data: KeyData) -> Double? {
        let b = data.bytes
        switch data.type {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let value = Float(bitPattern: bits)
            return value.isFinite ? Double(value) : nil
        case "sp78": // signed fixed point 7.8, big endian
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "fpe2": // unsigned fixed point 14.2, big endian
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        case "ui8 ":
            return b.first.map(Double.init)
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "si16":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
        default:
            return nil
        }
    }

    // MARK: - Plumbing

    private func call(_ input: ParamStruct) -> ParamStruct? {
        var input = input
        var output = ParamStruct()
        var outputSize = MemoryLayout<ParamStruct>.size
        let result = IOConnectCallStructMethod(
            connection, Self.handleYPCEvent,
            &input, MemoryLayout<ParamStruct>.size,
            &output, &outputSize
        )
        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private static func fourCC(_ string: String) -> UInt32? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { return nil }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    private static func fourCC(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
