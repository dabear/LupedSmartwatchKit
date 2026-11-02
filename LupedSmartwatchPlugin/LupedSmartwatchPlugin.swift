//
//  LupedSmartwatchPlugin.swift
//  LupedSmartwatchPlugin
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import os.log
import LoopKitUI
import LupedSmartwatchKit
import LupedSmartwatchKitUI

class LupedSmartwatchPlugin: NSObject, SmartwatchManagerUIPlugin {
    private let log = OSLog(subsystem: "org.loopkit.LupedSmartwatchKit", category: "LupedSmartwatchPlugin")

    public var smartwatchManagerType: SmartwatchManagerUI.Type? {
        return LupedSmartwatchManager.self
    }

    override init() {
        super.init()
        os_log("Instantiated", log: log, type: .default)
    }
}
