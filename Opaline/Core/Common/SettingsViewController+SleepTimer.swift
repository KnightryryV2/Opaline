import UIKit

// MARK: - Sleep timer settings (#44)

extension SettingsViewController {
    func handleSleepSelection(_ row: Row) -> Bool {
        switch row {
        case .sleepTimerMinutes:
            showSleepPicker(
                title: "settings.row.sleepTimerDuration".localized,
                options: SleepTimer.minuteOptions.map {
                    ($0, "settings.minutesCount".localized(with: $0))
                },
                current: SleepTimer.minutes
            ) { SleepTimer.minutes = $0 }
        case .sleepTimerDim:
            showSleepPicker(
                title: "settings.row.sleepTimerDim".localized,
                options: SleepTimer.dimOptions.map {
                    ($0, "settings.percentValue".localized(with: $0))
                },
                current: SleepTimer.dimLevel
            ) { SleepTimer.dimLevel = $0 }
        default:
            return false
        }
        return true
    }

    private func showSleepPicker(
        title: String,
        options: [(value: Int, label: String)],
        current: Int,
        apply: @escaping (Int) -> Void
    ) {
        let sheet = UIAlertController(
            title: title,
            message: nil,
            preferredStyle: .actionSheet
        )
        for option in options {
            let action = UIAlertAction(
                title: option.label,
                style: .default
            ) { [weak self] _ in
                apply(option.value)
                self?.reloadAllSettings()
            }
            if option.value == current {
                action.setValue(true, forKey: "checked")
            }
            sheet.addAction(action)
        }
        sheet.addAction(
            UIAlertAction(title: "common.cancel".localized, style: .cancel)
        )
        configureCenteredPopover(sheet)
        present(sheet, animated: true)
    }
}
