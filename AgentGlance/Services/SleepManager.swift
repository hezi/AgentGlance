import Foundation
import IOKit.pwr_mgt
import os

private let logger = Logger(subsystem: "app.agentglance", category: "SleepManager")

final class SleepManager {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isPreventingSleep = false

    func preventSleep() {
        guard !isPreventingSleep else { return }

        let reason = "Claude Code is actively working" as CFString
        let success = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )

        if success == kIOReturnSuccess {
            isPreventingSleep = true
            logger.info("Sleep prevention enabled")
        } else {
            logger.error("Failed to create sleep assertion: \(success)")
        }
    }

    func allowSleep() {
        guard isPreventingSleep else { return }

        let success = IOPMAssertionRelease(assertionID)
        if success == kIOReturnSuccess {
            isPreventingSleep = false
            logger.info("Sleep prevention disabled")
        } else {
            logger.error("Failed to release sleep assertion: \(success)")
        }
    }

    deinit {
        if isPreventingSleep {
            IOPMAssertionRelease(assertionID)
        }
    }
}
