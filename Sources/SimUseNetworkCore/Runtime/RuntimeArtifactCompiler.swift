// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct RuntimeArtifact: Equatable {
  package let libraryURL: URL
  package let architecture: String
  package let targetTriple: String
}

package struct RuntimeArtifactCompiler {
  private let processes: ProcessClient
  private let sourceURL: URL

  package init(processes: ProcessClient = .live, sourceURL: URL? = nil) throws {
    self.processes = processes
    if let sourceURL {
      self.sourceURL = sourceURL
    } else {
      guard
        let bundledSource = Bundle.module.url(
          forResource: "NetworkUnavailableShim",
          withExtension: "c",
          subdirectory: "RuntimeArtifacts"
        )
      else {
        throw SimUseNetworkError.invalidSession(
          "The bundled NetworkUnavailableShim.c resource is missing."
        )
      }
      self.sourceURL = bundledSource
    }
  }

  private init(resolvedProcesses: ProcessClient, resolvedSourceURL: URL) {
    processes = resolvedProcesses
    sourceURL = resolvedSourceURL
  }

  package func inheritingLease(from lock: DeviceLock) -> RuntimeArtifactCompiler {
    RuntimeArtifactCompiler(
      resolvedProcesses: processes.inheritingLease(from: lock),
      resolvedSourceURL: sourceURL
    )
  }

  package func compile(for runtime: SimulatorRuntime, in directory: URL) throws -> RuntimeArtifact {
    let hostArchitecture = try processes.checked(
      URL(filePath: "/usr/bin/uname"),
      ["-m"]
    ).standardOutput
    guard ["arm64", "x86_64"].contains(hostArchitecture),
      runtime.supportedArchitectures.contains(hostArchitecture)
    else {
      throw SimUseNetworkError.invalidInput(
        "Runtime \(runtime.name) does not support host architecture \(hostArchitecture)."
      )
    }
    guard runtime.version.allSatisfy({ $0.isNumber || $0 == "." }) else {
      throw SimUseNetworkError.invalidInput(
        "Runtime version contains unsupported characters: \(runtime.version)."
      )
    }

    let targetTriple =
      "\(hostArchitecture)-apple-\(runtime.platform.targetOS)\(runtime.version)-simulator"
    let outputURL = directory.appending(path: "libSimUseNetworkShim.dylib")
    let xcrun = URL(filePath: "/usr/bin/xcrun")
    _ = try processes.checked(
      xcrun,
      [
        "--sdk", runtime.platform.sdkName,
        "clang",
        "-target", targetTriple,
        "-dynamiclib",
        "-std=c17",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Wpedantic",
        "-Werror",
        "-fvisibility=hidden",
        "-fblocks",
        "-DSIM_USE_NETWORK_SHIM_ABI_VERSION=\(RuntimeCompatibility.shimABIVersion)",
        "-Wl,-install_name,@rpath/libSimUseNetworkShim.dylib",
        sourceURL.path,
        "-o", outputURL.path,
      ]
    )
    _ = try processes.checked(
      URL(filePath: "/usr/bin/codesign"),
      ["--force", "--sign", "-", "--timestamp=none", outputURL.path]
    )

    _ = try processes.checked(
      URL(filePath: "/usr/bin/codesign"),
      ["--verify", "--strict", outputURL.path]
    )
    let architectures = try processes.checked(
      xcrun,
      ["lipo", "-archs", outputURL.path]
    ).standardOutput.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard architectures == [hostArchitecture] else {
      throw SimUseNetworkError.verificationFailed(
        "Compiled shim architectures were \(architectures), expected only \(hostArchitecture)."
      )
    }
    let machHeader = try processes.checked(
      xcrun,
      ["otool", "-hv", outputURL.path]
    ).standardOutput
    guard machHeader.split(whereSeparator: { $0.isWhitespace }).contains("DYLIB") else {
      throw SimUseNetworkError.verificationFailed("Compiled shim is not a Mach-O dylib.")
    }
    let buildVersion = try processes.checked(
      xcrun,
      ["vtool", "-show-build", outputURL.path]
    ).standardOutput
    guard
      Self.loadCommandValue("platform", in: buildVersion)
        == runtime.platform.machOPlatformName,
      Self.loadCommandValue("minos", in: buildVersion) == runtime.version
    else {
      throw SimUseNetworkError.verificationFailed(
        "Compiled shim has the wrong LC_BUILD_VERSION platform or minimum OS."
      )
    }
    let linkedLibraries = try processes.checked(
      xcrun,
      ["otool", "-L", outputURL.path]
    ).standardOutput
    let dependencies =
      linkedLibraries
      .split(separator: "\n")
      .dropFirst()
      .compactMap { $0.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) }
    let allowedDependencies = Set([
      "@rpath/libSimUseNetworkShim.dylib",
      "/usr/lib/libSystem.B.dylib",
    ])
    guard Set(dependencies) == allowedDependencies else {
      throw SimUseNetworkError.verificationFailed(
        "Compiled shim links unexpected libraries: \(dependencies.joined(separator: ", "))."
      )
    }

    let symbols = try processes.checked(xcrun, ["nm", "-gU", outputURL.path]).standardOutput
    let expectedABISymbol = "_SimUseNetworkShimABIVersion_\(RuntimeCompatibility.shimABIVersion)"
    guard symbols.split(whereSeparator: { $0.isWhitespace }).contains(Substring(expectedABISymbol))
    else {
      throw SimUseNetworkError.verificationFailed(
        "Compiled shim does not export \(expectedABISymbol)."
      )
    }
    let undefinedSymbols = try processes.checked(
      xcrun,
      ["nm", "-u", outputURL.path]
    ).standardOutput.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let requiredReplacees = Set([
      "_socket", "_connect", "_connectx", "_send",
      "_sendto", "_sendmsg", "_write", "_writev",
      "_close", "_dup", "_dup2",
    ])
    guard requiredReplacees.isSubset(of: Set(undefinedSymbols)) else {
      throw SimUseNetworkError.verificationFailed(
        "Compiled shim does not bind every required interposed symbol."
      )
    }
    let loadCommands = try processes.checked(
      xcrun,
      ["otool", "-l", outputURL.path]
    ).standardOutput
    let expectedInterposeSize = UInt64(requiredReplacees.count * 2 * MemoryLayout<UInt>.size)
    guard let interposeSection = Self.interposeSection(in: loadCommands),
      ["__DATA", "__DATA_CONST"].contains(interposeSection.segment),
      interposeSection.size == expectedInterposeSize
    else {
      throw SimUseNetworkError.verificationFailed(
        "Compiled shim has an unexpected __DATA,__interpose tuple count."
      )
    }
    let fixups = try processes.checked(
      xcrun,
      ["dyld_info", "-fixups", outputURL.path]
    ).standardOutput
    let interposedReplacees = Set(
      fixups.split(separator: "\n").compactMap { line -> String? in
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.contains("__interpose"), fields.contains("bind"),
          let symbol = fields.last,
          let slash = symbol.lastIndex(of: "/")
        else {
          return nil
        }
        return String(symbol[symbol.index(after: slash)...])
      })
    guard interposedReplacees == requiredReplacees else {
      throw SimUseNetworkError.verificationFailed(
        "Compiled shim interpose fixups do not target the exact required symbol set."
      )
    }
    return RuntimeArtifact(
      libraryURL: outputURL,
      architecture: hostArchitecture,
      targetTriple: targetTriple
    )
  }

  private static func loadCommandValue(_ key: String, in output: String) -> String? {
    for line in output.split(separator: "\n") {
      let fields = line.split(whereSeparator: { $0.isWhitespace })
      if fields.count == 2, fields[0] == Substring(key) {
        return String(fields[1])
      }
    }
    return nil
  }

  private static func interposeSection(
    in output: String
  ) -> (segment: String, size: UInt64)? {
    var foundInterposeSection = false
    var segment: String?
    for line in output.split(separator: "\n") {
      let fields = line.split(whereSeparator: { $0.isWhitespace })
      if fields.count == 2, fields[0] == "sectname" {
        foundInterposeSection = fields[1] == "__interpose"
        segment = nil
        continue
      }
      if foundInterposeSection,
        fields.count == 2,
        fields[0] == "segname"
      {
        segment = String(fields[1])
        continue
      }
      if foundInterposeSection,
        fields.count == 2,
        fields[0] == "size",
        let segment,
        let size = UInt64(fields[1].dropFirst(2), radix: 16)
      {
        return (segment, size)
      }
    }
    return nil
  }
}
