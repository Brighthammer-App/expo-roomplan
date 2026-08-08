//  RoomPlanCaptureViewController.swift

import Foundation
import RealityKit
import RoomPlan
import UIKit
import AVFoundation

@available(iOS 17.0, *)
class RoomPlanCaptureViewController: UIViewController, RoomCaptureViewDelegate,
    RoomCaptureSessionDelegate
{
    private var roomCaptureView: RoomCaptureView!
    private var roomCaptureSessionConfig: RoomCaptureSession.Configuration =
        RoomCaptureSession.Configuration()
    private var isSessionRunning: Bool = false

    // AV preview — warms up the camera hardware before RoomPlan takes over.
    // Crossfades out when scanning starts.
    private var avSession: AVCaptureSession?
    private var avPreviewLayer: AVCaptureVideoPreviewLayer?
    private var avCaptureDevice: AVCaptureDevice?
    private var avRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var avRotationObservation: NSKeyValueObservation?

    private var finalResults: CapturedRoom?
    private var finalStructure: CapturedStructure?
    private let structureBuilder = StructureBuilder(options: [.beautifyObjects])

    var onDismiss: (([String: Any]) -> Void)?
    var onScanError: (([String: Any]) -> Void)?

    var scanName: String?
    var exportType: String?
    var sendFileLoc: Bool?
    var capturedRoomArray: [CapturedRoom] = []

    // Set to true when the user taps Done before didEndWith has finished building the room.
    // didEndWith will call exportResults() itself once the room is ready.
    private var exportPendingAfterBuild: Bool = false

    // UI elements
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    @IBOutlet var cancelButton: UIButton!
    @IBOutlet var finishButton: UIButton!
    @IBOutlet var anotherScanButton: UIButton!
    @IBOutlet var exportButton: UIButton!
    private var postScanCardView: UIView?
    private var errorCardView: UIView?
    private var lastDismissErrorCode: String?
    private var lastDismissErrorMessage: String?
    private var lastDismissErrorContext: String?
    private var backdropTopToFinishConstraint: NSLayoutConstraint!
    private var backdropTopToPostScanConstraint: NSLayoutConstraint?
    private var backdropTopToErrorCardConstraint: NSLayoutConstraint?
    private var errorCardTrailingConstraint: NSLayoutConstraint?

    /// Matches quick-camera `TABLET_RAIL_WIDTH` / `TABLET_MIN_DIMENSION` / `CameraShutterButton`.
    private let railWidth: CGFloat = 120
    private let tabletMinDimension: CGFloat = 768
    private let phoneFinishButtonSize: CGFloat = 72
    private let tabletFinishButtonSize: CGFloat = 84
    private let shutterBorderWidth: CGFloat = 4
    private let shutterRed = UIColor(red: 1, green: 59.0 / 255.0, blue: 48.0 / 255.0, alpha: 1)
    /// Quick camera `captureModeToggleWrap`: marginTop 12 + minHeight 44
    private let phoneShutterBelowChrome: CGFloat = 56

    private var sideRailView: UIView!
    private var sideRailWidthConstraint: NSLayoutConstraint!
    private var phoneFinishConstraints: [NSLayoutConstraint] = []
    private var phoneFinishBottomConstraint: NSLayoutConstraint!
    private var tabletFinishConstraints: [NSLayoutConstraint] = []
    private var tabletFinishCenterYConstraint: NSLayoutConstraint!
    private var phoneCancelConstraints: [NSLayoutConstraint] = []
    private var tabletCancelConstraints: [NSLayoutConstraint] = []
    private var cancelTopLeftConstraints: [NSLayoutConstraint] = []
    private var phoneReadyStatusConstraints: [NSLayoutConstraint] = []
    private var tabletReadyStatusConstraints: [NSLayoutConstraint] = []
    private var finishButtonWidthConstraint: NSLayoutConstraint!
    private var finishButtonHeightConstraint: NSLayoutConstraint!
    private var finishButtonInnerView: UIView!
    private var finishButtonInnerWidthConstraint: NSLayoutConstraint!
    private var finishButtonInnerHeightConstraint: NSLayoutConstraint!
    private var finishButtonShowsRecordingStyle: Bool = false
    private var backdropTrailingPhoneConstraint: NSLayoutConstraint!
    private var backdropTrailingTabletConstraint: NSLayoutConstraint!
    private var postScanCardTrailingConstraint: NSLayoutConstraint?
    private var readyStatusLabel: UILabel!
    /// True until the user taps start — drives finish-button start vs stop behavior.
    private var isReadyToStart: Bool = true

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupRoomCaptureView()
        setupActivityIndicator()
    }

    private func setupActivityIndicator() {
        activityIndicator.center = self.view.center
        activityIndicator.hidesWhenStopped = true
        activityIndicator.color = UIColor.white
        view.addSubview(activityIndicator)
    }

    // Solid black chrome sized by Auto Layout (phone bottom bar / post-scan) — matches quick camera.
    private var backdropView: UIView!

    private var isTabletLayout: Bool {
        min(view.bounds.width, view.bounds.height) >= tabletMinDimension
    }

    /// Phone: top safe area only (match quick camera `SafeAreaView edges={['top']}`).
    /// iPad: all safe-area edges; main column left of the 120pt trailing rail.
    private var availablePreviewRect: CGRect {
        let bounds = view.bounds
        let insets = view.safeAreaInsets

        if !isTabletLayout {
            return CGRect(
                x: 0,
                y: insets.top,
                width: bounds.width,
                height: max(0, bounds.height - insets.top)
            )
        }

        let width = max(0, bounds.width - insets.left - insets.right - railWidth)
        let height = max(0, bounds.height - insets.top - insets.bottom)
        return CGRect(x: insets.left, y: insets.top, width: width, height: height)
    }

    /// Fit a 4:3 rectangle inside `available`.
    /// Portrait uses 3:4 (width:height); landscape uses 4:3.
    /// Phone: top-aligned. iPad: centered in the main column (does not overlap the rail).
    private func previewFrame(in available: CGRect) -> CGRect {
        guard available.width > 0, available.height > 0 else { return .zero }

        let isLandscape = available.width > available.height
        let targetAspect = isLandscape ? (4.0 / 3.0) : (3.0 / 4.0) // width / height
        let availableAspect = available.width / available.height

        let size: CGSize
        if availableAspect > targetAspect {
            // Available is wider than target — height-constrained
            let height = available.height
            size = CGSize(width: height * targetAspect, height: height)
        } else {
            // Available is taller/narrower than target — width-constrained
            let width = available.width
            size = CGSize(width: width, height: width / targetAspect)
        }

        let x = available.minX + (available.width - size.width) / 2
        let y: CGFloat
        if isTabletLayout {
            y = available.minY + (available.height - size.height) / 2
        } else {
            y = available.minY
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func layoutCameraSurfaces() {
        let frame = previewFrame(in: availablePreviewRect)
        roomCaptureView.frame = frame
        avPreviewLayer?.frame = frame
        applyAVPreviewRotation()
    }

    /// Allow iPad landscape so RoomPlan / AV preview can follow the interface.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        return .allButUpsideDown
    }

    override var shouldAutorotate: Bool { true }

    override func viewWillTransition(
        to size: CGSize,
        with coordinator: UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in
            self.applyControlLayout()
            self.layoutCameraSurfaces()
        })
    }

    private func setupRoomCaptureView() {
        // Temporary frame — sized to 4:3 in viewDidLayoutSubviews.
        roomCaptureView = RoomCaptureView(frame: view.bounds)
        roomCaptureView?.captureSession.delegate = self
        // Hide until scanning starts so the AV warm-up preview shows through underneath
        roomCaptureView?.alpha = 0
        view.insertSubview(roomCaptureView, at: 0)

        setupButtons()
        setupConstraints()
        applyControlLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        applyControlLayout()
        layoutCameraSurfaces()
    }

    /// Shutter dims matching `CameraShutterButton` video mode (phone / tablet).
    private func shutterInnerDims(recording: Bool) -> (size: CGFloat, cornerRadius: CGFloat) {
        let tablet = isTabletLayout
        if recording {
            return tablet ? (32, 6) : (28, 5)
        }
        let inner = tablet ? 66.0 : 58.0
        return (inner, inner / 2)
    }

    private func applyFinishButtonAppearance(animated: Bool) {
        let outer = isTabletLayout ? tabletFinishButtonSize : phoneFinishButtonSize
        let dims = shutterInnerDims(recording: finishButtonShowsRecordingStyle)

        let updates = {
            self.finishButton.layer.cornerRadius = outer / 2
            self.finishButtonInnerWidthConstraint.constant = dims.size
            self.finishButtonInnerHeightConstraint.constant = dims.size
            self.finishButtonInnerView.layer.cornerRadius = dims.cornerRadius
            self.finishButtonInnerView.backgroundColor = self.shutterRed
            self.finishButton.layoutIfNeeded()
        }

        if animated {
            UIView.animate(withDuration: 0.2, animations: updates)
        } else {
            updates()
        }
    }

    private func setupButtons() {
        // Record/stop — matches quick-camera video shutter (white ring + red inner / stop square)
        finishButton = UIButton(type: .custom)
        finishButton.translatesAutoresizingMaskIntoConstraints = false
        finishButton.backgroundColor = .clear
        finishButton.layer.masksToBounds = true
        finishButton.layer.cornerRadius = phoneFinishButtonSize / 2
        finishButton.layer.borderWidth = shutterBorderWidth
        finishButton.layer.borderColor = UIColor.white.cgColor
        finishButton.accessibilityLabel = "Start scanning"

        finishButtonInnerView = UIView()
        finishButtonInnerView.translatesAutoresizingMaskIntoConstraints = false
        finishButtonInnerView.isUserInteractionEnabled = false
        finishButtonInnerView.backgroundColor = shutterRed
        finishButtonInnerView.layer.masksToBounds = true
        let idleDims = shutterInnerDims(recording: false)
        finishButtonInnerView.layer.cornerRadius = idleDims.cornerRadius
        finishButton.addSubview(finishButtonInnerView)

        finishButtonInnerWidthConstraint = finishButtonInnerView.widthAnchor.constraint(
            equalToConstant: idleDims.size
        )
        finishButtonInnerHeightConstraint = finishButtonInnerView.heightAnchor.constraint(
            equalToConstant: idleDims.size
        )
        NSLayoutConstraint.activate([
            finishButtonInnerView.centerXAnchor.constraint(equalTo: finishButton.centerXAnchor),
            finishButtonInnerView.centerYAnchor.constraint(equalTo: finishButton.centerYAnchor),
            finishButtonInnerWidthConstraint,
            finishButtonInnerHeightConstraint,
        ])

        finishButton.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)

        // Solid black chrome — height driven by content via Auto Layout (phone / post-scan)
        backdropView = UIView()
        backdropView.backgroundColor = .black
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.isUserInteractionEnabled = false
        view.addSubview(backdropView)

        // iPad right rail (matches quick-camera tabletSideRail look)
        sideRailView = UIView()
        sideRailView.translatesAutoresizingMaskIntoConstraints = false
        sideRailView.backgroundColor = UIColor.white.withAlphaComponent(0.04)
        sideRailView.isHidden = true
        let railBorder = CALayer()
        railBorder.name = "railBorder"
        railBorder.backgroundColor = UIColor.white.withAlphaComponent(0.08).cgColor
        sideRailView.layer.addSublayer(railBorder)
        view.addSubview(sideRailView)

        view.addSubview(finishButton)

        // Cancel — frosted pill (inspired by quick-camera Done)
        cancelButton = UIButton(type: .system)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        applyCancelButtonChrome(emphasized: false)
        cancelButton.addTarget(self, action: #selector(cancelSession), for: .touchUpInside)
        view.addSubview(cancelButton)

        // Ready status — calm status line above the shutter (no dim overlay)
        readyStatusLabel = UILabel()
        readyStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        readyStatusLabel.textAlignment = .center
        readyStatusLabel.numberOfLines = 1
        readyStatusLabel.isUserInteractionEnabled = false
        readyStatusLabel.alpha = 0
        readyStatusLabel.layer.shadowColor = UIColor.black.cgColor
        readyStatusLabel.layer.shadowOpacity = 0.4
        readyStatusLabel.layer.shadowRadius = 10
        readyStatusLabel.layer.shadowOffset = CGSize(width: 0, height: 1)
        applyReadyStatusTypography()
        view.addSubview(readyStatusLabel)
    }

    private func applyReadyStatusTypography() {
        let size: CGFloat = 20
        let base = UIFont.systemFont(ofSize: size, weight: .semibold)
        let font: UIFont
        if let rounded = base.fontDescriptor.withDesign(.rounded) {
            font = UIFont(descriptor: rounded, size: size)
        } else {
            font = base
        }
        readyStatusLabel.attributedText = NSAttributedString(
            string: "Ready to scan",
            attributes: [
                .font: font,
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .kern: 0.6,
            ]
        )
    }

    /// Show only on the pre-scan ready screen.
    private func updateReadyStatusVisibility(animated: Bool = false) {
        let show =
            isReadyToStart
            && !isSessionRunning
            && postScanCardView == nil
            && errorCardView == nil
        let updates = {
            self.readyStatusLabel.alpha = show ? 1 : 0
        }
        if animated {
            UIView.animate(
                withDuration: 0.4,
                delay: show ? 0.05 : 0,
                options: [.curveEaseOut],
                animations: updates
            )
        } else {
            updates()
        }
    }

    /// Frosted pill chrome inspired by quick-camera Done (`rgba(255,255,255,0.12)` + hairline).
    /// Emphasized (post-scan / error): dark pill so it stays readable on RoomPlan's light mesh.
    private func applyCancelButtonChrome(emphasized: Bool, railStyle: Bool = false) {
        var config = UIButton.Configuration.plain()
        config.title = "Cancel"
        config.baseForegroundColor = UIColor.white.withAlphaComponent(0.96)
        // Rail (tablet ready): tighter insets like `doneButtonRail`. Top-left / phone: Done padding.
        let horizontal: CGFloat = railStyle ? 16 : 20
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 11, leading: horizontal, bottom: 11, trailing: horizontal
        )
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            outgoing.kern = 0.35
            return outgoing
        }
        if emphasized {
            // Dark fill — RoomCaptureView often shows a near-white mesh after stop.
            config.background.backgroundColor = UIColor.black.withAlphaComponent(0.72)
            config.background.strokeColor = UIColor.white.withAlphaComponent(0.4)
        } else {
            config.background.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            config.background.strokeColor = UIColor.white.withAlphaComponent(0.32)
        }
        config.background.cornerRadius = 22
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        config.background.strokeWidth = 1.0 / scale
        cancelButton.configuration = config
        if !isSessionRunning {
            cancelButton.alpha = cancelButton.isEnabled ? 1.0 : 0.4
        }
    }

    /// Hide Cancel while scanning (mirrors quick-camera Done during recording).
    private func updateCancelButtonVisibility(animated: Bool = false) {
        let shouldHide = isSessionRunning
        let updates = {
            if shouldHide {
                self.cancelButton.alpha = 0
                self.cancelButton.isUserInteractionEnabled = false
            } else {
                self.cancelButton.alpha = self.cancelButton.isEnabled ? 1.0 : 0.4
                self.cancelButton.isUserInteractionEnabled = self.cancelButton.isEnabled
            }
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: updates)
        } else {
            updates()
        }
    }

    private func setupConstraints() {
        backdropTopToFinishConstraint = backdropView.topAnchor.constraint(
            equalTo: finishButton.topAnchor, constant: -20
        )
        backdropTrailingPhoneConstraint = backdropView.trailingAnchor.constraint(
            equalTo: view.trailingAnchor
        )
        backdropTrailingTabletConstraint = backdropView.trailingAnchor.constraint(
            equalTo: sideRailView.leadingAnchor
        )

        finishButtonWidthConstraint = finishButton.widthAnchor.constraint(
            equalToConstant: phoneFinishButtonSize
        )
        finishButtonHeightConstraint = finishButton.heightAnchor.constraint(
            equalToConstant: phoneFinishButtonSize
        )
        sideRailWidthConstraint = sideRailView.widthAnchor.constraint(equalToConstant: 0)

        // Phone: match quick camera shutter Y (toggle row reserve + paddingBottom)
        phoneFinishBottomConstraint = finishButton.bottomAnchor.constraint(
            equalTo: view.bottomAnchor, constant: -20
        )
        phoneFinishConstraints = [
            phoneFinishBottomConstraint,
            finishButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ]

        // iPad: pin shutter to true mid-rail (matches quick-camera absolute centerY).
        tabletFinishCenterYConstraint = finishButton.centerYAnchor.constraint(
            equalTo: sideRailView.centerYAnchor, constant: 0
        )
        tabletFinishConstraints = [
            finishButton.centerXAnchor.constraint(equalTo: sideRailView.centerXAnchor),
            tabletFinishCenterYConstraint,
        ]

        // Phone: left of shutter (mirror of quick-camera Done on the right) — ready only
        phoneCancelConstraints = [
            cancelButton.centerYAnchor.constraint(equalTo: finishButton.centerYAnchor),
            cancelButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20
            ),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ]
        // iPad: above shutter in the side rail (gap matches quick-camera rail `gap: 28`) — ready only
        tabletCancelConstraints = [
            cancelButton.centerXAnchor.constraint(equalTo: sideRailView.centerXAnchor),
            cancelButton.bottomAnchor.constraint(
                equalTo: finishButton.topAnchor, constant: -28
            ),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            cancelButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: sideRailView.leadingAnchor, constant: 8
            ),
            cancelButton.trailingAnchor.constraint(
                lessThanOrEqualTo: sideRailView.trailingAnchor, constant: -8
            ),
        ]
        // Post-scan / error: top-left escape — clear of the bottom sheet
        cancelTopLeftConstraints = [
            cancelButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12
            ),
            cancelButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16
            ),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ]

        // Ready status: phone above shutter; tablet centered in main column
        phoneReadyStatusConstraints = [
            readyStatusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            readyStatusLabel.bottomAnchor.constraint(
                equalTo: finishButton.topAnchor, constant: -28
            ),
            readyStatusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 32
            ),
            readyStatusLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -32
            ),
        ]
        tabletReadyStatusConstraints = [
            readyStatusLabel.centerYAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.centerYAnchor
            ),
            readyStatusLabel.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32
            ),
            readyStatusLabel.trailingAnchor.constraint(
                equalTo: sideRailView.leadingAnchor, constant: -16
            ),
        ]

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropTrailingPhoneConstraint,

            sideRailView.topAnchor.constraint(equalTo: view.topAnchor),
            sideRailView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sideRailView.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor
            ),
            sideRailWidthConstraint,

            finishButtonWidthConstraint,
            finishButtonHeightConstraint,
        ])
    }

    /// Swap phone bottom chrome vs iPad right rail; hide bottom bar on iPad while scanning.
    private func applyControlLayout() {
        let tablet = isTabletLayout
        let isPostScan = postScanCardView != nil
        let isErrorCard = errorCardView != nil
        let showBottomChrome = isPostScan || isErrorCard

        sideRailView.isHidden = !tablet
        sideRailView.isUserInteractionEnabled = tablet
        sideRailWidthConstraint.constant = tablet ? railWidth : 0

        // Hairline on the rail's leading edge
        if tablet, let border = sideRailView.layer.sublayers?.first(where: { $0.name == "railBorder" }) {
            let scale = view.window?.screen.scale ?? UIScreen.main.scale
            border.frame = CGRect(x: 0, y: 0, width: 1.0 / scale, height: sideRailView.bounds.height)
        }

        NSLayoutConstraint.deactivate(phoneFinishConstraints)
        NSLayoutConstraint.deactivate(tabletFinishConstraints)
        NSLayoutConstraint.deactivate(phoneCancelConstraints)
        NSLayoutConstraint.deactivate(tabletCancelConstraints)
        NSLayoutConstraint.deactivate(cancelTopLeftConstraints)
        NSLayoutConstraint.deactivate(phoneReadyStatusConstraints)
        NSLayoutConstraint.deactivate(tabletReadyStatusConstraints)

        if tablet {
            NSLayoutConstraint.activate(tabletFinishConstraints)
            finishButtonWidthConstraint.constant = tabletFinishButtonSize
            finishButtonHeightConstraint.constant = tabletFinishButtonSize

            backdropTrailingPhoneConstraint.isActive = false
            backdropTrailingTabletConstraint.isActive = true
            // No bottom chrome during scan on iPad
            backdropView.isHidden = !showBottomChrome
            if !showBottomChrome {
                backdropTopToFinishConstraint.isActive = false
            }
        } else {
            NSLayoutConstraint.activate(phoneFinishConstraints)
            finishButtonWidthConstraint.constant = phoneFinishButtonSize
            finishButtonHeightConstraint.constant = phoneFinishButtonSize
            // Match quick camera shutter Y: paddingBottom + Photo/Video toggle reserve
            phoneFinishBottomConstraint.constant =
                -(max(view.safeAreaInsets.bottom, 12) + 8 + phoneShutterBelowChrome)

            backdropTrailingTabletConstraint.isActive = false
            backdropTrailingPhoneConstraint.isActive = true
            backdropView.isHidden = false
            if !showBottomChrome {
                backdropTopToFinishConstraint.isActive = true
            }
        }

        // Ready: beside shutter. Post-scan / error: top-left (clear of the sheet).
        if showBottomChrome {
            NSLayoutConstraint.activate(cancelTopLeftConstraints)
        } else if tablet {
            NSLayoutConstraint.activate(tabletCancelConstraints)
        } else {
            NSLayoutConstraint.activate(phoneCancelConstraints)
        }

        if tablet {
            NSLayoutConstraint.activate(tabletReadyStatusConstraints)
        } else {
            NSLayoutConstraint.activate(phoneReadyStatusConstraints)
        }

        applyFinishButtonAppearance(animated: false)
        applyCancelButtonChrome(
            emphasized: showBottomChrome,
            railStyle: tablet && !showBottomChrome
        )
        updateCancelButtonVisibility(animated: false)
        updateReadyStatusVisibility(animated: false)

        if tablet {
            view.bringSubviewToFront(sideRailView)
        }
        view.bringSubviewToFront(finishButton)
        view.bringSubviewToFront(cancelButton)
        view.bringSubviewToFront(readyStatusLabel)
        if let card = postScanCardView {
            view.bringSubviewToFront(card)
            view.bringSubviewToFront(cancelButton)
        }
        if let errorCard = errorCardView {
            view.bringSubviewToFront(errorCard)
            view.bringSubviewToFront(cancelButton)
        }
    }

    private func makePostScanActionButton(
        title: String,
        isPrimary: Bool
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        button.layer.cornerRadius = 14
        button.layer.masksToBounds = true
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        button.setTitle(title, for: .normal)

        if isPrimary {
            button.backgroundColor = UIColor.systemBlue
            button.setTitleColor(.white, for: .normal)
            button.setTitleColor(UIColor.white.withAlphaComponent(0.65), for: .disabled)
        } else {
            button.backgroundColor = UIColor.white.withAlphaComponent(0.14)
            button.setTitleColor(.white, for: .normal)
            button.layer.borderWidth = 1
            button.layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        }

        return button
    }

    private func setupPostScanUI() {
        guard postScanCardView == nil else { return }

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        card.layer.cornerRadius = 20
        card.layer.masksToBounds = true
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        postScanCardView = card
        view.addSubview(card)
        view.bringSubviewToFront(card)
        view.bringSubviewToFront(cancelButton)

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Room scan captured"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.numberOfLines = 0

        let helperLabel = UILabel()
        helperLabel.translatesAutoresizingMaskIntoConstraints = false
        helperLabel.text =
            "Scan another room to add it to this floor plan, or finish to create the final floor plan."
        helperLabel.textColor = UIColor.white.withAlphaComponent(0.88)
        helperLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        helperLabel.numberOfLines = 0

        anotherScanButton = makePostScanActionButton(
            title: "Scan Another Room",
            isPrimary: false
        )
        anotherScanButton.addTarget(
            self,
            action: #selector(restartSession),
            for: .touchUpInside
        )

        exportButton = makePostScanActionButton(
            title: "Finish Floor Plan",
            isPrimary: true
        )
        exportButton.addTarget(
            self,
            action: #selector(confirmFinishFloorPlan),
            for: .touchUpInside
        )

        let buttonStack = UIStackView(arrangedSubviews: [
            anotherScanButton, exportButton,
        ])
        buttonStack.axis = .vertical
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = UIStackView(arrangedSubviews: [
            titleLabel, helperLabel, buttonStack,
        ])
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setCustomSpacing(16, after: helperLabel)
        card.addSubview(contentStack)

        backdropTopToFinishConstraint.isActive = false
        backdropTopToPostScanConstraint = backdropView.topAnchor.constraint(
            equalTo: card.topAnchor, constant: -12
        )
        backdropTopToPostScanConstraint?.isActive = true
        backdropView.isHidden = false
        // Don't intercept taps above the sheet (Cancel lives top-left).
        backdropView.isUserInteractionEnabled = false

        applyCancelButtonChrome(emphasized: true)
        cancelButton.alpha = 1
        cancelButton.isUserInteractionEnabled = cancelButton.isEnabled

        card.alpha = 0
        card.transform = CGAffineTransform(translationX: 0, y: 24)
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0.4,
            options: .curveEaseOut
        ) {
            card.alpha = 1
            card.transform = .identity
        }

        let cardTrailing: NSLayoutConstraint
        if isTabletLayout {
            cardTrailing = card.trailingAnchor.constraint(
                equalTo: sideRailView.leadingAnchor, constant: -16
            )
        } else {
            cardTrailing = card.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -16
            )
        }
        postScanCardTrailingConstraint = cardTrailing

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            cardTrailing,
            card.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16
            ),

            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])

        applyControlLayout()
        view.bringSubviewToFront(cancelButton)
    }

    private func teardownPostScanUI() {
        postScanCardView?.removeFromSuperview()
        postScanCardView = nil
        postScanCardTrailingConstraint = nil
        backdropTopToPostScanConstraint?.isActive = false
        backdropTopToPostScanConstraint = nil
        backdropView.isUserInteractionEnabled = false
        applyControlLayout()
    }

    // MARK: - Scan error card

    private struct ScanErrorCopy {
        let code: String
        let title: String
        let message: String
    }

    private func captureErrorCopy(from error: RoomCaptureSession.CaptureError) -> ScanErrorCopy {
        switch error {
        case .exceedSceneSizeLimit:
            return ScanErrorCopy(
                code: "exceedSceneSizeLimit",
                title: "Scan area too large",
                message: "This scan covered more space than RoomPlan can handle. Finish with what you have, or start a new scan for another area."
            )
        case .deviceTooHot:
            return ScanErrorCopy(
                code: "deviceTooHot",
                title: "Device too warm",
                message: "Your device needs to cool down before scanning can continue. Wait a minute, then try again."
            )
        case .worldTrackingFailure:
            return ScanErrorCopy(
                code: "worldTrackingFailure",
                title: "Tracking lost",
                message: "Move slowly with good lighting, and avoid mirrors or reflective surfaces. Then try again."
            )
        case .deviceNotSupported:
            return ScanErrorCopy(
                code: "deviceNotSupported",
                title: "Scanning not supported",
                message: "This device doesn’t support LiDAR room scanning."
            )
        case .invalidARConfiguration:
            return ScanErrorCopy(
                code: "invalidARConfiguration",
                title: "Camera setup failed",
                message: "Something went wrong with the camera session. Close and try again."
            )
        case .internalError:
            return ScanErrorCopy(
                code: "internalError",
                title: "Scan interrupted",
                message: "Room scanning hit an unexpected problem. Try again, or close and start over."
            )
        @unknown default:
            return ScanErrorCopy(
                code: "unknown",
                title: "Scan interrupted",
                message: "Room scanning was interrupted. Try again, or close and start over."
            )
        }
    }

    private func emitScanError(message: String, context: String, code: String?) {
        var payload: [String: Any] = [
            "errorMessage": message,
            "errorContext": context,
        ]
        if let code {
            payload["errorCode"] = code
        }
        let deliver = {
            self.lastDismissErrorMessage = message
            self.lastDismissErrorContext = context
            self.lastDismissErrorCode = code
            self.onScanError?(payload)
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    private enum ScanErrorPrimaryAction {
        case `continue`
        case tryAgain
        case retryExport
        case closeOnly
    }

    private func teardownErrorCard() {
        errorCardView?.removeFromSuperview()
        errorCardView = nil
        errorCardTrailingConstraint = nil
        backdropTopToErrorCardConstraint?.isActive = false
        backdropTopToErrorCardConstraint = nil
        if postScanCardView == nil {
            backdropView.isUserInteractionEnabled = false
        }
        applyControlLayout()
    }

    private func showErrorCard(
        title: String,
        message: String,
        primaryAction: ScanErrorPrimaryAction
    ) {
        DispatchQueue.main.async {
            self.renderErrorCard(title: title, message: message, primaryAction: primaryAction)
        }
    }

    private func renderErrorCard(
        title: String,
        message: String,
        primaryAction: ScanErrorPrimaryAction
    ) {
        teardownErrorCard()
        // Keep post-scan chrome available for Continue / retry-export; hide it under the error card.
        switch primaryAction {
        case .continue, .retryExport:
            postScanCardView?.isHidden = true
        case .tryAgain, .closeOnly:
            teardownPostScanUI()
        }

        view.viewWithTag(887)?.removeFromSuperview()
        finishButton.isHidden = true
        isSessionRunning = false

        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor.black.withAlphaComponent(0.42)
        card.layer.cornerRadius = 20
        card.layer.masksToBounds = true
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        errorCardView = card
        view.addSubview(card)

        let accent = UIView()
        accent.translatesAutoresizingMaskIntoConstraints = false
        accent.backgroundColor = UIColor.systemOrange
        accent.layer.cornerRadius = 2
        accent.layer.masksToBounds = true

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = title
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.numberOfLines = 0

        let helperLabel = UILabel()
        helperLabel.translatesAutoresizingMaskIntoConstraints = false
        helperLabel.text = message
        helperLabel.textColor = UIColor.white.withAlphaComponent(0.88)
        helperLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        helperLabel.numberOfLines = 0

        var arranged: [UIView] = [titleLabel, helperLabel]

        switch primaryAction {
        case .continue:
            let continueButton = makePostScanActionButton(title: "Continue", isPrimary: true)
            continueButton.addTarget(self, action: #selector(errorCardContinueTapped), for: .touchUpInside)
            let closeButton = makePostScanActionButton(title: "Close", isPrimary: false)
            closeButton.addTarget(self, action: #selector(errorCardCloseTapped), for: .touchUpInside)
            let stack = UIStackView(arrangedSubviews: [continueButton, closeButton])
            stack.axis = .vertical
            stack.spacing = 12
            arranged.append(stack)
        case .tryAgain:
            let tryAgainButton = makePostScanActionButton(title: "Try Again", isPrimary: true)
            tryAgainButton.addTarget(self, action: #selector(errorCardTryAgainTapped), for: .touchUpInside)
            let closeButton = makePostScanActionButton(title: "Close", isPrimary: false)
            closeButton.addTarget(self, action: #selector(errorCardCloseTapped), for: .touchUpInside)
            let stack = UIStackView(arrangedSubviews: [tryAgainButton, closeButton])
            stack.axis = .vertical
            stack.spacing = 12
            arranged.append(stack)
        case .retryExport:
            let tryAgainButton = makePostScanActionButton(title: "Try Again", isPrimary: true)
            tryAgainButton.addTarget(self, action: #selector(errorCardRetryExportTapped), for: .touchUpInside)
            let closeButton = makePostScanActionButton(title: "Close", isPrimary: false)
            closeButton.addTarget(self, action: #selector(errorCardCloseTapped), for: .touchUpInside)
            let stack = UIStackView(arrangedSubviews: [tryAgainButton, closeButton])
            stack.axis = .vertical
            stack.spacing = 12
            arranged.append(stack)
        case .closeOnly:
            let closeButton = makePostScanActionButton(title: "Close", isPrimary: true)
            closeButton.addTarget(self, action: #selector(errorCardCloseTapped), for: .touchUpInside)
            arranged.append(closeButton)
        }

        let contentStack = UIStackView(arrangedSubviews: arranged)
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.setCustomSpacing(16, after: helperLabel)
        card.addSubview(accent)
        card.addSubview(contentStack)

        backdropTopToFinishConstraint.isActive = false
        backdropTopToPostScanConstraint?.isActive = false
        backdropTopToErrorCardConstraint = backdropView.topAnchor.constraint(
            equalTo: card.topAnchor, constant: -12
        )
        backdropTopToErrorCardConstraint?.isActive = true
        backdropView.isHidden = false
        // Sheet chrome only — don't block top-left Cancel.
        backdropView.isUserInteractionEnabled = false

        cancelButton.isEnabled = true
        applyCancelButtonChrome(emphasized: true)
        cancelButton.alpha = 1
        cancelButton.isUserInteractionEnabled = true

        card.alpha = 0
        card.transform = CGAffineTransform(translationX: 0, y: 24)
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0.4,
            options: .curveEaseOut
        ) {
            card.alpha = 1
            card.transform = .identity
        }

        let cardTrailing: NSLayoutConstraint
        if isTabletLayout {
            cardTrailing = card.trailingAnchor.constraint(
                equalTo: sideRailView.leadingAnchor, constant: -16
            )
        } else {
            cardTrailing = card.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -16
            )
        }
        errorCardTrailingConstraint = cardTrailing

        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            accent.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            accent.widthAnchor.constraint(equalToConstant: 4),
            accent.heightAnchor.constraint(equalToConstant: 22),

            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            cardTrailing,
            card.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16
            ),

            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])

        applyControlLayout()
        view.bringSubviewToFront(cancelButton)
    }

    @objc private func errorCardContinueTapped() {
        teardownErrorCard()
        postScanCardView?.isHidden = false
        if postScanCardView == nil {
            setupPostScanUI()
        } else {
            backdropTopToPostScanConstraint?.isActive = true
            backdropView.isUserInteractionEnabled = false
            applyControlLayout()
        }
    }

    @objc private func errorCardTryAgainTapped() {
        // Clear export overlay if present
        view.viewWithTag(999)?.removeFromSuperview()
        teardownErrorCard()
        restorePostScanActionButtons()
        restartSession()
    }

    @objc private func errorCardRetryExportTapped() {
        view.viewWithTag(999)?.removeFromSuperview()
        teardownErrorCard()
        restorePostScanActionButtons()
        if postScanCardView == nil {
            setupPostScanUI()
        } else {
            postScanCardView?.isHidden = false
            backdropTopToPostScanConstraint?.isActive = true
            backdropView.isUserInteractionEnabled = false
            applyControlLayout()
        }
        // Re-attempt finish/export with the rooms we already have
        superExportResults(exportButton as Any)
    }

    private func restorePostScanActionButtons() {
        if exportButton != nil {
            exportButton.isEnabled = true
            exportButton.backgroundColor = UIColor.systemBlue
            exportButton.removeTarget(nil, action: nil, for: .allEvents)
            exportButton.addTarget(
                self,
                action: #selector(confirmFinishFloorPlan),
                for: .touchUpInside
            )
        }
        if anotherScanButton != nil {
            anotherScanButton.isEnabled = true
            anotherScanButton.backgroundColor = UIColor.white.withAlphaComponent(0.14)
            anotherScanButton.removeTarget(nil, action: nil, for: .allEvents)
            anotherScanButton.addTarget(
                self,
                action: #selector(restartSession),
                for: .touchUpInside
            )
        }
        cancelButton.isEnabled = true
        cancelButton.alpha = 1
        cancelButton.removeTarget(nil, action: nil, for: .allEvents)
        cancelButton.addTarget(self, action: #selector(cancelSession), for: .touchUpInside)
        applyCancelButtonChrome(emphasized: true)
    }

    @objc private func errorCardCloseTapped() {
        teardownErrorCard()
        sendScanResultAndDismiss(
            status: .Error,
            errorMessage: lastDismissErrorMessage,
            errorContext: lastDismissErrorContext ?? "captureError",
            errorCode: lastDismissErrorCode
        )
    }

    private func prepareScanningUIForCaptureFailure() {
        DispatchQueue.main.async {
            self.isSessionRunning = false
            self.exportPendingAfterBuild = false
            self.view.viewWithTag(887)?.removeFromSuperview()
            self.finishButton.isHidden = true
        }
    }

    @objc private func confirmFinishFloorPlan() {
        let alert = UIAlertController(
            title: "Finish floor plan?",
            message:
                "This will create the final floor plan from all scanned rooms. You won't be able to add more rooms to this scan afterward.",
            preferredStyle: .alert
        )

        alert.addAction(
            UIAlertAction(title: "Keep Scanning", style: .cancel, handler: nil)
        )
        alert.addAction(
            UIAlertAction(title: "Finish Floor Plan", style: .default) { _ in
                self.superExportResults(self.exportButton as Any)
            }
        )

        present(alert, animated: true, completion: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startAVPreview()
        updateReadyStatusVisibility(animated: true)
    }

    override func viewWillDisappear(_ flag: Bool) {
        super.viewWillDisappear(flag)
        stopAVPreview()
        stopSession()
    }

    // MARK: - AV Camera Preview (warm-up)

    private func startAVPreview() {
        // Check permission first — if not granted, silently skip (RoomPlan will handle it)
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        let session = AVCaptureSession()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = previewFrame(in: availablePreviewRect)
        // Insert behind everything — RoomCaptureView is at index 0, so go below it
        view.layer.insertSublayer(previewLayer, at: 0)

        avSession = session
        avPreviewLayer = previewLayer
        avCaptureDevice = device

        // Keep the warm-up preview level with gravity across portrait/landscape (iPad).
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        avRotationCoordinator = coordinator
        avRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coord, _ in
            self?.applyAVPreviewRotation(angle: coord.videoRotationAngleForHorizonLevelPreview)
        }
        applyAVPreviewRotation()

        // Start on a background thread so we don't block the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
            DispatchQueue.main.async {
                self.applyAVPreviewRotation()
            }
        }
    }

    private func applyAVPreviewRotation(angle: CGFloat? = nil) {
        guard let connection = avPreviewLayer?.connection else { return }
        let rotation =
            angle
            ?? avRotationCoordinator?.videoRotationAngleForHorizonLevelPreview
            ?? videoRotationAngleForInterfaceOrientation()
        guard connection.isVideoRotationAngleSupported(rotation) else { return }
        connection.videoRotationAngle = rotation
    }

    private func videoRotationAngleForInterfaceOrientation() -> CGFloat {
        let orientation =
            view.window?.windowScene?.interfaceOrientation
            ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation
            ?? .portrait
        switch orientation {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeRight: return 180
        case .landscapeLeft: return 0
        default: return 90
        }
    }

    private func stopAVPreview() {
        avRotationObservation?.invalidate()
        avRotationObservation = nil
        avRotationCoordinator = nil
        avCaptureDevice = nil
        avPreviewLayer?.removeFromSuperlayer()
        avPreviewLayer = nil
        let session = avSession
        avSession = nil
        DispatchQueue.global(qos: .userInitiated).async {
            session?.stopRunning()
        }
    }

    @IBAction func superExportResults(_ sender: Any) {
        // disable buttons after pressing upload
        exportButton.isEnabled = false
        exportButton.removeTarget(
            self,
            action: #selector(confirmFinishFloorPlan),
            for: .touchUpInside
        )
        // Also disable Finish to avoid exiting mid-export
        finishButton.isEnabled = false
        anotherScanButton.isEnabled = false
        anotherScanButton.removeTarget(
            self,
            action: #selector(restartSession),
            for: .touchUpInside
        )
        UIView.animate(withDuration: 0.5) {
            self.anotherScanButton.backgroundColor = UIColor.white
            self.exportButton.backgroundColor = UIColor.white
        }

        // create a white overlay view that covers the entire screen
        let overlayView = UIView(frame: self.view.bounds)
        overlayView.backgroundColor = UIColor.white
        overlayView.alpha = 1
        overlayView.tag = 999

        // add the overlay above the roomCaptureView but below other UI elements
        self.view.insertSubview(overlayView, aboveSubview: roomCaptureView!)

        // If the session is still running, stopping it will fire didEndWith which builds the
        // room asynchronously. Mark export as pending so didEndWith triggers exportResults()
        // once the room is ready, instead of racing with the 0.5s delay below.
        if isSessionRunning {
            exportPendingAfterBuild = true
            roomCaptureView?.captureSession.stop(pauseARSession: true)
        } else {
            // Session already stopped (user tapped stop first, then Done) — room is built,
            // safe to export after the brief overlay animation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.exportResults()
            }
        }
    }

    func exportResults() {
        let exportedScanName = scanName ?? "Room"

        let destinationFolderURL = FileManager.default.temporaryDirectory
            .appending(path: "Export")
        let destinationURL = destinationFolderURL.appending(path: "\(exportedScanName).usdz")
        let capturedRoomURL = destinationFolderURL.appending(path: "\(exportedScanName).json")

        // UI responsiveness, disable cancel button
        cancelButton.removeTarget(
            self,
            action: #selector(cancelSession),
            for: .touchUpInside
        )
        cancelButton.isEnabled = false
        UIView.transition(
            with: cancelButton,
            duration: 0.2,
            options: .transitionCrossDissolve,
            animations: {
                self.applyCancelButtonChrome(emphasized: false)
                self.cancelButton.alpha = 0.4
            },
            completion: nil
        )

        Task {
            do {
                finalStructure = try await structureBuilder.capturedStructure(
                    from: capturedRoomArray
                )

                try FileManager.default.createDirectory(
                    at: destinationFolderURL,
                    withIntermediateDirectories: true
                )
                
                var finalExportType = CapturedRoom.USDExportOptions.parametric;
                
                if (exportType == "MESH") {
                    finalExportType = CapturedRoom.USDExportOptions.mesh;
                } else if (exportType == "MODEL") {
                    finalExportType = CapturedRoom.USDExportOptions.model;
                }

                let jsonEncoder = JSONEncoder()
                let jsonData = try jsonEncoder.encode(finalStructure)
                try jsonData.write(to: capturedRoomURL)
                try finalStructure?.export(
                    to: destinationURL,
                    exportOptions: finalExportType
                )

                // reset finalStructure before sending data
                finalStructure = nil
                
                let shouldSendFileLoc = sendFileLoc ?? false

                if (shouldSendFileLoc) {
                    self.sendScanResultAndDismiss(status: .OK, scanUrl: destinationURL.absoluteString, jsonUrl: capturedRoomURL.absoluteString)
                    return
                }

                let activityVC = UIActivityViewController(
                    activityItems: [destinationFolderURL],
                    applicationActivities: nil
                )
                activityVC.modalPresentationStyle = .popover

                activityVC.completionWithItemsHandler = {
                    activityType,
                    completed,
                    returnedItems,
                    activityError in
                    self.sendScanResultAndDismiss(status: .OK)
                }

                if let popOver = activityVC.popoverPresentationController {
                    popOver.sourceView = self.exportButton
                }

                present(activityVC, animated: true, completion: nil)

            } catch {
                print("[RoomPlan] ERROR MERGING: \(error)")
                let message = error.localizedDescription
                self.emitScanError(message: message, context: "exportResults", code: "exportFailed")
                DispatchQueue.main.async {
                    // Remove white export overlay so the error card is visible
                    self.view.viewWithTag(999)?.removeFromSuperview()
                    self.restorePostScanActionButtons()
                    let hasRooms = !self.capturedRoomArray.isEmpty
                    self.showErrorCard(
                        title: "Couldn’t finish floor plan",
                        message: "Something went wrong while combining your scans. \(hasRooms ? "Try again, or close and start over." : message)",
                        primaryAction: hasRooms ? .retryExport : .closeOnly
                    )
                }
                return
            }
        }
    }

    func sendScanResultAndDismiss(status: ScanStatus? = nil, scanUrl: String? = nil, jsonUrl: String? = nil, errorMessage: String? = nil, errorContext: String? = nil, errorCode: String? = nil) {
        var eventData: [String: Any] = [:]

        if let status = status {
            eventData["status"] = status.rawValue
        }

        if let jsonUrl = jsonUrl {
            eventData["jsonUrl"] = jsonUrl
        }

        if let scanUrl = scanUrl {
            eventData["scanUrl"] = scanUrl
        }

        if let errorMessage = errorMessage {
            eventData["errorMessage"] = errorMessage
        }

        if let errorContext = errorContext {
            eventData["errorContext"] = errorContext
        }

        if let errorCode = errorCode {
            eventData["errorCode"] = errorCode
        }
        
        // Send the unified event
        onDismiss?(eventData)
        
        let dismissAction = {
            self.activityIndicator.stopAnimating()
            self.dismiss(animated: true, completion: nil)
        }
        
        // Handle timing and cleanup based on status
        if status == .OK {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + 0.5,
                execute: dismissAction
            )
        } else {
            finalStructure = nil
            DispatchQueue.main.async(execute: dismissAction)
        }
    }

    public func startSession() {
        print("[RoomPlan] starting session")
        isReadyToStart = false
        isSessionRunning = true
        setFinishButtonToRecording()
        showScanningHint()
        updateCancelButtonVisibility(animated: true)
        updateReadyStatusVisibility(animated: true)

        // Stop the AV preview and hand the camera off to RoomPlan.
        // We stop on a background thread then call run() on main once it's done —
        // this avoids the two sessions fighting over the camera at the same time,
        // which is the source of the freeze/spike on first start.
        let sessionToStop = avSession
        avSession = nil
        let layerToFade = avPreviewLayer
        avPreviewLayer = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            sessionToStop?.stopRunning()
            DispatchQueue.main.async {
                guard let self else { return }
                self.roomCaptureView?.captureSession.run(configuration: self.roomCaptureSessionConfig)
                // Crossfade: bring RoomCaptureView in while fading the AV preview out
                UIView.animate(withDuration: 0.2) {
                    self.roomCaptureView?.alpha = 1
                }
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.2)
                layerToFade?.opacity = 0
                CATransaction.setCompletionBlock { layerToFade?.removeFromSuperlayer() }
                CATransaction.commit()
            }
        }
    }

    private func showScanningHint() {
        // Remove any existing hint first
        view.viewWithTag(887)?.removeFromSuperview()

        let hint = UILabel()
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.tag = 887
        hint.text = "Scan one room/area, then tap stop."
        hint.textColor = .white
        hint.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        hint.layer.cornerRadius = 10
        hint.layer.masksToBounds = true
        hint.isUserInteractionEnabled = false
        view.insertSubview(hint, belowSubview: finishButton)

        let tablet = isTabletLayout
        if tablet {
            NSLayoutConstraint.activate([
                hint.leadingAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32
                ),
                hint.trailingAnchor.constraint(
                    equalTo: sideRailView.leadingAnchor, constant: -16
                ),
                hint.bottomAnchor.constraint(
                    equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24
                ),
            ])
        } else {
            NSLayoutConstraint.activate([
                hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                hint.bottomAnchor.constraint(equalTo: finishButton.topAnchor, constant: -20),
                hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
                hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            ])
        }
    }

    @IBAction func restartSession() {
        print("[RoomPlan] restarting session")
        exportPendingAfterBuild = false
        teardownErrorCard()
        teardownPostScanUI()
        roomCaptureView?.captureSession.run(configuration: roomCaptureSessionConfig)
        isSessionRunning = true
        isReadyToStart = false
        // Restore the record button
        setFinishButtonToRecording()
        finishButton.isHidden = false
        showScanningHint()
        cancelButton.isEnabled = true
        applyCancelButtonChrome(emphasized: false)
        updateCancelButtonVisibility(animated: true)
    }

    @objc
    public func stopSession() {
        roomCaptureView?.captureSession.stop(pauseARSession: false)
        isSessionRunning = false
        // Remove scanning hint
        view.viewWithTag(887)?.removeFromSuperview()
        // Hide the record button — post-scan UI has its own actions
        finishButton.isHidden = true
        // Show Cancel immediately (no fade race with post-scan layout).
        updateCancelButtonVisibility(animated: false)
        setupPostScanUI()
    }

    @objc
    private func finishTapped() {
        if isReadyToStart {
            // Not yet started — tap starts the scan
            startSession()
        } else if isSessionRunning {
            // Currently scanning — tap stops and shows post-scan UI
            stopSession()
        } else {
            // Post-scan and button somehow visible — shouldn't happen, but safe fallback
            sendScanResultAndDismiss(status: .OK)
        }
    }

    private func setFinishButtonToRecording() {
        finishButtonShowsRecordingStyle = true
        finishButton.accessibilityLabel = "Stop scanning"
        finishButton.isEnabled = true
        applyFinishButtonAppearance(animated: true)
    }

    private func setFinishButtonToIdle() {
        finishButtonShowsRecordingStyle = false
        finishButton.accessibilityLabel = "Start scanning"
        finishButton.isEnabled = true
        applyFinishButtonAppearance(animated: true)
    }

    @objc
    func cancelSession() {
        let alertController = UIAlertController(
            title: "Cancel Room Scan?",
            message:
                "If a scan is canceled, you'll have to start over again next time.",
            preferredStyle: .alert
        )

        let confirmAction = UIAlertAction(title: "Confirm", style: .destructive)
        { action in
            // reset final structure on cancel
            self.finalStructure = nil
            self.sendScanResultAndDismiss(status: .Canceled)
        }
        alertController.addAction(confirmAction)

        let cancelAction = UIAlertAction(
            title: "Cancel",
            style: .cancel,
            handler: nil
        )
        alertController.addAction(cancelAction)

        self.present(alertController, animated: true, completion: nil)
    }

    @objc
    static func requiresMainQueueSetup() -> Bool {
        return true
    }
}

@available(iOS 17.0, *)
extension RoomPlanCaptureViewController {
    func captureSession(_ session: RoomCaptureSession, didUpdate: CapturedRoom)
    {
        print("[RoomPlan] didUpdate", didUpdate.objects.count)
    }

    func captureSession(_ session: RoomCaptureSession, didChange: CapturedRoom)
    {
        print("[RoomPlan] didChange", didChange.objects.count)
    }

    func captureSession(
        _ session: RoomCaptureSession,
        didEndWith: CapturedRoomData,
        error: (any Error)?
    ) {
        print("[RoomPlan] didEndWith")

        let captureCopy: ScanErrorCopy?
        if let captureError = error as? RoomCaptureSession.CaptureError {
            let copy = captureErrorCopy(from: captureError)
            captureCopy = copy
            emitScanError(message: copy.message, context: "captureError", code: copy.code)
            prepareScanningUIForCaptureFailure()
        } else if let error {
            let message = error.localizedDescription
            captureCopy = ScanErrorCopy(code: "unknown", title: "Scan interrupted", message: message)
            emitScanError(message: message, context: "captureError", code: "unknown")
            prepareScanningUIForCaptureFailure()
        } else {
            captureCopy = nil
        }

        let roomBuilder = RoomBuilder(options: [.beautifyObjects])
        Task {
            var builtRoom = false
            do {
                let capturedRoom = try await roomBuilder.capturedRoom(from: didEndWith)
                print("[RoomPlan] Appending new captured room")
                self.capturedRoomArray.append(capturedRoom)
                builtRoom = true
            } catch {
                // Non-fatal: user stays in the scan UI and can try again.
                print("[RoomPlan] Failed to build captured room: \(error)")
                let message = error.localizedDescription
                self.emitScanError(message: message, context: "roomBuilder", code: "roomBuilderFailed")
                if captureCopy == nil {
                    let hasPriorRooms = !self.capturedRoomArray.isEmpty
                    self.showErrorCard(
                        title: "Couldn’t process this room",
                        message: "The scan finished, but the room model couldn’t be built. \(hasPriorRooms ? "You can continue with previous rooms or try again." : "Try scanning again.")",
                        primaryAction: hasPriorRooms ? .continue : .tryAgain
                    )
                }
            }

            // CaptureError: surface after attempting to keep partial results.
            if let captureCopy {
                let hasRooms = !self.capturedRoomArray.isEmpty || builtRoom
                let primary: ScanErrorPrimaryAction
                switch captureCopy.code {
                case "deviceNotSupported":
                    primary = .closeOnly
                default:
                    primary = hasRooms ? .continue : .tryAgain
                }
                self.showErrorCard(
                    title: captureCopy.title,
                    message: captureCopy.message,
                    primaryAction: primary
                )
                // Don't auto-export when RoomPlan ended with a capture error.
                self.exportPendingAfterBuild = false
                return
            }

            // If Done was tapped while the session was still running, export now that the
            // room is built rather than relying on the fixed 0.5s delay in superExportResults.
            if self.exportPendingAfterBuild {
                self.exportPendingAfterBuild = false
                DispatchQueue.main.async {
                    self.exportResults()
                }
            }
        }
    }
}

@available(iOS 17.0, *)
extension RoomPlanCaptureViewController {
    func captureView(
        shouldPresent roomDataForProcessing: CapturedRoomData,
        error: Error?
    ) -> Bool {
        return true
    }

    // access the final results
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        finalResults = processedResult
    }
}
