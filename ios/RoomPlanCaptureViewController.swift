//  RoomPlanCaptureViewController.swift

import ARKit
import Foundation
import RealityKit
import RoomPlan
import UIKit
import AVFoundation

@available(iOS 17.0, *)
class RoomPlanCaptureViewController: UIViewController, RoomCaptureViewDelegate,
    RoomCaptureSessionDelegate, ARSessionDelegate
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
    private var postScanTitleLabel: UILabel?
    private var postScanHelperLabel: UILabel?
    private var rescanRoomButton: UIButton?
    /// Expected room total while the just-stopped room is still building (array lags by ~1).
    private var postScanExpectedRoomCount: Int = 0
    /// User tapped Rescan before the stopped room finished building — drop it on append.
    private var discardNextAppendedRoom: Bool = false
    /// True from Stop until room build (+ merge dry-run for room 2+) finishes.
    private var isPostScanAwaitingValidation: Bool = false
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

    /// RoomCaptureView is pinned with Auto Layout (full available area). Never frame-mutate mid-scan.
    private var phoneRoomCaptureConstraints: [NSLayoutConstraint] = []
    private var tabletRoomCaptureConstraints: [NSLayoutConstraint] = []
    /// Last bounds used for AV warm-up layout — skip no-op updates.
    private var lastAVPreviewLayoutBounds: CGRect = .null
    /// Track phone↔tablet so we only re-apply control layout on size-class change.
    private var lastAppliedTabletLayout: Bool?

    /// Set while ARKit has suspended camera capture (backgrounding, screen lock,
    /// incoming call). ARKit does not resume capture on its own — the session must be
    /// re-run — so we track the suspension and recover on interruption end / becoming
    /// active. Without this the passthrough stays black while RoomPlan keeps rendering
    /// the mesh it already has, and the scan can only be discarded.
    private var isARSessionInterrupted: Bool = false

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

    /// Same rect as RoomCaptureView so warm-up → scan doesn’t jump aspect ratio.
    /// Phone: full host view (edge to edge). iPad: safe-area main column left of the rail.
    private var roomCaptureMatchingFrame: CGRect {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        if !isTabletLayout {
            return bounds
        }

        let insets = view.safeAreaInsets
        let width = max(0, bounds.width - insets.left - insets.right - railWidth)
        let height = max(0, bounds.height - insets.top - insets.bottom)
        return CGRect(x: insets.left, y: insets.top, width: width, height: height)
    }

    /// Update AV warm-up layer to match RoomCaptureView’s area when host bounds change.
    /// Does not touch RoomCaptureView — that view is Auto Layout pinned for the life of the VC.
    private func layoutAVPreviewIfNeeded(force: Bool = false) {
        guard avPreviewLayer != nil else { return }
        let bounds = view.bounds
        if !force, bounds == lastAVPreviewLayoutBounds { return }
        lastAVPreviewLayoutBounds = bounds
        avPreviewLayer?.frame = roomCaptureMatchingFrame
        applyAVPreviewRotation()
    }

    private func updateRailBorderFrame() {
        guard isTabletLayout,
              let border = sideRailView.layer.sublayers?.first(where: { $0.name == "railBorder" })
        else { return }
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        border.frame = CGRect(x: 0, y: 0, width: 1.0 / scale, height: sideRailView.bounds.height)
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
            self.layoutAVPreviewIfNeeded(force: true)
        })
    }

    private func setupRoomCaptureView() {
        // Full-area RoomCaptureView (Apple sample pattern). Warm-up uses the same rect.
        roomCaptureView = RoomCaptureView(frame: .zero)
        roomCaptureView.translatesAutoresizingMaskIntoConstraints = false
        roomCaptureView.captureSession.delegate = self
        // Observe the underlying ARSession so interruptions (screen lock, call,
        // backgrounding) and hard AR failures are visible to us. RoomCaptureSession
        // forwards nothing about either.
        roomCaptureView.captureSession.arSession.delegate = self
        // Hide until scanning starts so the AV warm-up preview shows through underneath
        roomCaptureView.alpha = 0
        view.insertSubview(roomCaptureView, at: 0)

        setupButtons()
        setupConstraints()
        applyControlLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Size-class change (e.g. iPad Split View) — not every layout pass.
        let tablet = isTabletLayout
        if lastAppliedTabletLayout != tablet {
            applyControlLayout()
        } else {
            // Safe-area can settle after first layout; keep shutter inset correct without constraint churn.
            if !tablet {
                phoneFinishBottomConstraint.constant =
                    -(max(view.safeAreaInsets.bottom, 12) + 8 + phoneShutterBelowChrome)
            }
            updateRailBorderFrame()
        }

        layoutAVPreviewIfNeeded()
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
        }

        if animated {
            UIView.animate(withDuration: 0.2) {
                updates()
                self.finishButton.layoutIfNeeded()
            }
        } else {
            // Avoid layoutIfNeeded here — applyControlLayout may run from viewDidLayoutSubviews.
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
        // Don't force alpha here — updateCancelButtonVisibility owns scan / post-scan hide.
    }

    /// Hide Cancel while scanning or on the post-scan decision card (actions live on the card).
    private func updateCancelButtonVisibility(animated: Bool = false) {
        let postScanVisible =
            postScanCardView != nil && !(postScanCardView?.isHidden ?? true)
        let shouldHide = isSessionRunning || postScanVisible
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
        // Phone: full host view (Apple sample). Tablet: main column left of the rail.
        phoneRoomCaptureConstraints = [
            roomCaptureView.topAnchor.constraint(equalTo: view.topAnchor),
            roomCaptureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            roomCaptureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            roomCaptureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]
        tabletRoomCaptureConstraints = [
            roomCaptureView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            roomCaptureView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            roomCaptureView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            roomCaptureView.trailingAnchor.constraint(equalTo: sideRailView.leadingAnchor),
        ]

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
    /// Call on setup, scan/post-scan/error transitions, and rotation / size-class change — not every layout pass.
    private func applyControlLayout() {
        let tablet = isTabletLayout
        lastAppliedTabletLayout = tablet
        let isPostScan = postScanCardView != nil
        let isErrorCard = errorCardView != nil
        let showBottomChrome = isPostScan || isErrorCard

        sideRailView.isHidden = !tablet
        sideRailView.isUserInteractionEnabled = tablet
        sideRailWidthConstraint.constant = tablet ? railWidth : 0

        NSLayoutConstraint.deactivate(phoneRoomCaptureConstraints)
        NSLayoutConstraint.deactivate(tabletRoomCaptureConstraints)
        NSLayoutConstraint.deactivate(phoneFinishConstraints)
        NSLayoutConstraint.deactivate(tabletFinishConstraints)
        NSLayoutConstraint.deactivate(phoneCancelConstraints)
        NSLayoutConstraint.deactivate(tabletCancelConstraints)
        NSLayoutConstraint.deactivate(cancelTopLeftConstraints)
        NSLayoutConstraint.deactivate(phoneReadyStatusConstraints)
        NSLayoutConstraint.deactivate(tabletReadyStatusConstraints)

        if tablet {
            NSLayoutConstraint.activate(tabletRoomCaptureConstraints)
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
            NSLayoutConstraint.activate(phoneRoomCaptureConstraints)
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

        updateRailBorderFrame()

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

    private func makePostScanTertiaryButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        button.setTitle(title, for: .normal)
        // Soft red on dark sheet — scoped destructive (discard last room).
        button.setTitleColor(UIColor.systemRed.withAlphaComponent(0.92), for: .normal)
        button.setTitleColor(UIColor.systemRed.withAlphaComponent(0.4), for: .disabled)
        button.backgroundColor = .clear
        return button
    }

    private func setupPostScanUI() {
        guard postScanCardView == nil else {
            updatePostScanCopy()
            return
        }

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
        titleLabel.text = "Room scanned"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.numberOfLines = 0
        postScanTitleLabel = titleLabel

        let helperLabel = UILabel()
        helperLabel.translatesAutoresizingMaskIntoConstraints = false
        helperLabel.textColor = UIColor.white.withAlphaComponent(0.88)
        helperLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
        helperLabel.numberOfLines = 0
        postScanHelperLabel = helperLabel

        // Primary (top): scan next — secondary: done — tertiary text: rescan
        anotherScanButton = makePostScanActionButton(
            title: "Scan next room",
            isPrimary: true
        )
        anotherScanButton.addTarget(
            self,
            action: #selector(restartSession),
            for: .touchUpInside
        )

        exportButton = makePostScanActionButton(
            title: "Done scanning",
            isPrimary: false
        )
        exportButton.addTarget(
            self,
            action: #selector(confirmFinishFloorPlan),
            for: .touchUpInside
        )

        let rescanButton = makePostScanTertiaryButton(title: "Rescan this room")
        rescanButton.addTarget(
            self,
            action: #selector(rescanLastRoomTapped),
            for: .touchUpInside
        )
        rescanRoomButton = rescanButton

        let buttonStack = UIStackView(arrangedSubviews: [
            anotherScanButton, exportButton, rescanButton,
        ])
        buttonStack.axis = .vertical
        buttonStack.spacing = 12
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.setCustomSpacing(8, after: exportButton)

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
        // Don't intercept taps above the sheet.
        backdropView.isUserInteractionEnabled = false

        // Decision actions live on the card — hide top-left Cancel.
        updateCancelButtonVisibility(animated: false)

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
        updateCancelButtonVisibility(animated: false)
        updatePostScanCopy()
        if isPostScanAwaitingValidation {
            setPostScanActionsEnabled(false)
        }
    }

    private func updatePostScanCopy() {
        if isPostScanAwaitingValidation {
            postScanTitleLabel?.text = "Checking floor plan…"
            // Room 2+: dry-run merge; room 1: waiting on RoomBuilder only.
            let willMerge =
                capturedRoomArray.count >= 2 || postScanExpectedRoomCount >= 2
            postScanHelperLabel?.text =
                willMerge
                ? "Making sure this room fits with your other scans."
                : "Processing this room…"
            return
        }

        let count = max(capturedRoomArray.count, postScanExpectedRoomCount, 1)
        let roomWord = count == 1 ? "room" : "rooms"
        postScanTitleLabel?.text = "Room scanned"
        postScanHelperLabel?.text =
            "\(count) \(roomWord) done. Scan the next room, or finish if you’re done."
    }

    /// Gate Scan next / Done / Rescan until room build (+ merge dry-run) completes.
    private func setPostScanActionsEnabled(_ enabled: Bool) {
        guard postScanCardView != nil else { return }
        anotherScanButton?.isEnabled = enabled
        anotherScanButton?.alpha = enabled ? 1.0 : 0.45
        exportButton?.isEnabled = enabled
        exportButton?.alpha = enabled ? 1.0 : 0.45
        rescanRoomButton?.isEnabled = enabled
        rescanRoomButton?.alpha = enabled ? 1.0 : 0.45
    }

    @objc private func rescanLastRoomTapped() {
        let alert = UIAlertController(
            title: "Rescan this room?",
            message: "This replaces the last room you scanned. Your other rooms stay.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(
            UIAlertAction(title: "Rescan", style: .destructive) { [weak self] _ in
                self?.performRescanLastRoom()
            }
        )
        present(alert, animated: true, completion: nil)
    }

    private func performRescanLastRoom() {
        if !capturedRoomArray.isEmpty {
            capturedRoomArray.removeLast()
            discardNextAppendedRoom = false
        } else {
            // Build still in flight after Stop — drop that room when it arrives.
            discardNextAppendedRoom = true
        }
        postScanExpectedRoomCount = capturedRoomArray.count
        restartSession()
    }

    private func teardownPostScanUI() {
        postScanCardView?.removeFromSuperview()
        postScanCardView = nil
        postScanTitleLabel = nil
        postScanHelperLabel = nil
        rescanRoomButton = nil
        postScanCardTrailingConstraint = nil
        backdropTopToPostScanConstraint?.isActive = false
        backdropTopToPostScanConstraint = nil
        backdropView.isUserInteractionEnabled = false
        isPostScanAwaitingValidation = false
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
        /// Prior rooms kept; failed room discarded — rescan / finish / exit.
        case recover
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

    private func recoveryHelperMessage(priorRoomCount: Int) -> String {
        let roomWord = priorRoomCount == 1 ? "room" : "rooms"
        return
            "This room wasn’t saved. We kept your other \(priorRoomCount) \(roomWord). Rescan this one, or finish with what you have."
    }

    private func makeExitWithoutSavingButton(isPrimary: Bool) -> UIButton {
        let button = makePostScanActionButton(
            title: "Exit without saving",
            isPrimary: isPrimary
        )
        button.addTarget(
            self,
            action: #selector(errorCardExitWithoutSavingTapped),
            for: .touchUpInside
        )
        return button
    }

    private func renderErrorCard(
        title: String,
        message: String,
        primaryAction: ScanErrorPrimaryAction
    ) {
        teardownErrorCard()
        // Recovery / try-again replace post-scan chrome; retry-export may still need it.
        switch primaryAction {
        case .retryExport:
            postScanCardView?.isHidden = true
        case .recover, .tryAgain, .closeOnly:
            teardownPostScanUI()
        }

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
        case .recover:
            let rescanButton = makePostScanActionButton(
                title: "Rescan room",
                isPrimary: true
            )
            rescanButton.addTarget(
                self,
                action: #selector(errorCardTryAgainTapped),
                for: .touchUpInside
            )
            let doneButton = makePostScanActionButton(
                title: "Done scanning",
                isPrimary: false
            )
            doneButton.addTarget(
                self,
                action: #selector(confirmFinishFloorPlan),
                for: .touchUpInside
            )
            let exitButton = makeExitWithoutSavingButton(isPrimary: false)
            let stack = UIStackView(arrangedSubviews: [rescanButton, doneButton, exitButton])
            stack.axis = .vertical
            stack.spacing = 12
            arranged.append(stack)
        case .tryAgain:
            let tryAgainButton = makePostScanActionButton(title: "Try again", isPrimary: true)
            tryAgainButton.addTarget(
                self,
                action: #selector(errorCardTryAgainTapped),
                for: .touchUpInside
            )
            let exitButton = makeExitWithoutSavingButton(isPrimary: false)
            let stack = UIStackView(arrangedSubviews: [tryAgainButton, exitButton])
            stack.axis = .vertical
            stack.spacing = 12
            arranged.append(stack)
        case .retryExport:
            let tryAgainButton = makePostScanActionButton(title: "Try again", isPrimary: true)
            tryAgainButton.addTarget(
                self,
                action: #selector(errorCardRetryExportTapped),
                for: .touchUpInside
            )
            let exitButton = makeExitWithoutSavingButton(isPrimary: false)
            let stack = UIStackView(arrangedSubviews: [tryAgainButton, exitButton])
            stack.axis = .vertical
            stack.spacing = 12
            arranged.append(stack)
        case .closeOnly:
            arranged.append(makeExitWithoutSavingButton(isPrimary: true))
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
        if anotherScanButton != nil {
            anotherScanButton.isEnabled = true
            anotherScanButton.alpha = 1.0
            anotherScanButton.backgroundColor = UIColor.systemBlue
            anotherScanButton.removeTarget(nil, action: nil, for: .allEvents)
            anotherScanButton.addTarget(
                self,
                action: #selector(restartSession),
                for: .touchUpInside
            )
        }
        if exportButton != nil {
            exportButton.isEnabled = true
            exportButton.alpha = 1.0
            exportButton.backgroundColor = UIColor.white.withAlphaComponent(0.14)
            exportButton.removeTarget(nil, action: nil, for: .allEvents)
            exportButton.addTarget(
                self,
                action: #selector(confirmFinishFloorPlan),
                for: .touchUpInside
            )
        }
        rescanRoomButton?.isEnabled = true
        rescanRoomButton?.alpha = 1.0
        cancelButton.isEnabled = true
        cancelButton.removeTarget(nil, action: nil, for: .allEvents)
        cancelButton.addTarget(self, action: #selector(cancelSession), for: .touchUpInside)
        applyCancelButtonChrome(emphasized: true)
        updateCancelButtonVisibility(animated: false)
    }

    @objc private func errorCardExitWithoutSavingTapped() {
        let roomCount = capturedRoomArray.count
        guard roomCount > 0 else {
            dismissScanWithoutSaving()
            return
        }

        let alert = UIAlertController(
            title: "Exit without saving?",
            message: "Rooms from this scan won’t be saved.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        alert.addAction(
            UIAlertAction(title: "Exit", style: .destructive) { [weak self] _ in
                self?.dismissScanWithoutSaving()
            }
        )
        present(alert, animated: true, completion: nil)
    }

    private func dismissScanWithoutSaving() {
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
            self.finishButton.isHidden = true
        }
    }

    @objc private func confirmFinishFloorPlan() {
        let alert = UIAlertController(
            title: "Done scanning?",
            message:
                "We’ll build the floor plan from the rooms you scanned. You can’t add more rooms to this scan afterward.",
            preferredStyle: .alert
        )

        alert.addAction(
            UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        )
        alert.addAction(
            UIAlertAction(title: "Finish", style: .default) { _ in
                self.superExportResults(self.exportButton as Any)
            }
        )

        present(alert, animated: true, completion: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Belt and braces with the JS-side keep-awake lock: a scan is minutes of
        // walking with no touches, and letting the screen lock suspends ARKit capture.
        UIApplication.shared.isIdleTimerDisabled = true
        startAVPreview()
        updateReadyStatusVisibility(animated: true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    override func viewWillDisappear(_ flag: Bool) {
        super.viewWillDisappear(flag)
        UIApplication.shared.isIdleTimerDisabled = false
        NotificationCenter.default.removeObserver(
            self,
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        stopAVPreview()
        stopSession()
    }

    // MARK: - AR session interruption recovery

    /// Backstop for `sessionInterruptionEnded`, which does not fire reliably for every
    /// suspension path (notably screen lock on some devices). Only acts if we saw an
    /// interruption and a scan is actually in flight.
    @objc private func handleAppDidBecomeActive() {
        guard isARSessionInterrupted, isSessionRunning else { return }
        resumeARSessionAfterInterruption()
    }

    /// Re-run the capture session so ARKit resumes delivering camera frames. Tracking
    /// state is not recoverable across a suspension, so relocalization is left to ARKit;
    /// what matters is that passthrough comes back instead of staying black.
    private func resumeARSessionAfterInterruption() {
        guard isARSessionInterrupted else { return }
        isARSessionInterrupted = false
        guard isSessionRunning else { return }
        print("[RoomPlan] resuming capture session after interruption")
        roomCaptureView?.captureSession.run(configuration: roomCaptureSessionConfig)
        roomCaptureView?.alpha = 1
    }

    func sessionWasInterrupted(_ session: ARSession) {
        print("[RoomPlan] ARSession interrupted")
        isARSessionInterrupted = true
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        print("[RoomPlan] ARSession interruption ended")
        DispatchQueue.main.async { [weak self] in
            self?.resumeARSessionAfterInterruption()
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Surface AR-level failures, which otherwise leave the user on a silent black
        // screen: the existing error card is only reachable from didEndWith.
        let message = error.localizedDescription
        print("[RoomPlan] ARSession failed: \(message)")
        emitScanError(message: message, context: "arSession", code: "arSessionFailed")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let priorCount = self.capturedRoomArray.count
            // Also clears isSessionRunning and exportPendingAfterBuild.
            self.prepareScanningUIForCaptureFailure()
            self.showErrorCard(
                title: "Camera stopped",
                message: priorCount > 0
                    ? self.recoveryHelperMessage(priorRoomCount: priorCount)
                    : "The camera stopped unexpectedly. Try scanning this room again.",
                primaryAction: priorCount > 0 ? .recover : .tryAgain
            )
        }
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
        // Insert behind everything — RoomCaptureView is at index 0, so go below it
        view.layer.insertSublayer(previewLayer, at: 0)

        avSession = session
        avPreviewLayer = previewLayer
        avCaptureDevice = device
        lastAVPreviewLayoutBounds = .null
        layoutAVPreviewIfNeeded(force: true)

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
                self.layoutAVPreviewIfNeeded(force: true)
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
        lastAVPreviewLayoutBounds = .null
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
        rescanRoomButton?.isEnabled = false
        rescanRoomButton?.removeTarget(
            nil,
            action: nil,
            for: .allEvents
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

    @IBAction func restartSession() {
        // Return to Ready UI so the user can reposition before the next pass.
        // Do not call captureSession.run or restart AV preview — RoomPlan may still
        // hold the camera after stop(pauseARSession: false); bringing AV back risks
        // freezes. Keep roomCaptureView as the backdrop; Start calls startSession().
        print("[RoomPlan] returning to ready for next room")
        exportPendingAfterBuild = false
        // Keep discardNextAppendedRoom if Rescan set it; clear only for normal Scan next.
        // rescanLastRoomTapped sets the flag before calling restartSession.
        teardownErrorCard()
        teardownPostScanUI()

        if isSessionRunning {
            roomCaptureView?.captureSession.stop(pauseARSession: false)
        }

        isSessionRunning = false
        isReadyToStart = true
        roomCaptureView?.alpha = 1

        setFinishButtonToIdle()
        finishButton.isHidden = false
        cancelButton.isEnabled = true
        applyControlLayout()
        updateCancelButtonVisibility(animated: true)
        updateReadyStatusVisibility(animated: true)
    }

    @objc
    public func stopSession() {
        roomCaptureView?.captureSession.stop(pauseARSession: false)
        isSessionRunning = false
        // Hide the record button — post-scan UI has its own actions
        finishButton.isHidden = true
        // Show Cancel immediately (no fade race with post-scan layout).
        updateCancelButtonVisibility(animated: false)
        // Array append lags until room build finishes — expect current room too.
        postScanExpectedRoomCount = capturedRoomArray.count + 1
        isPostScanAwaitingValidation = true
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

    /// Return to the post-scan decision card while keeping rooms already in `capturedRoomArray`.
    /// Uses continuous AR session (`pauseARSession: false`) — same as Stop / Rescan.
    private func returnToPostScanKeepingRooms() {
        exportPendingAfterBuild = false
        teardownErrorCard()

        if isSessionRunning {
            // Drop the in-flight room; keep prior rooms only.
            discardNextAppendedRoom = true
            roomCaptureView?.captureSession.stop(pauseARSession: false)
            isSessionRunning = false
        }

        isReadyToStart = false
        finishButton.isHidden = true
        postScanExpectedRoomCount = capturedRoomArray.count
        isPostScanAwaitingValidation = false

        if postScanCardView != nil {
            postScanCardView?.isHidden = false
            backdropTopToFinishConstraint.isActive = false
            backdropTopToPostScanConstraint?.isActive = true
            backdropView.isHidden = false
            backdropView.isUserInteractionEnabled = false
            updatePostScanCopy()
            setPostScanActionsEnabled(true)
            applyControlLayout()
        } else {
            setupPostScanUI()
            setPostScanActionsEnabled(true)
        }

        updateCancelButtonVisibility(animated: false)
        updateReadyStatusVisibility(animated: true)
    }

    @objc
    func cancelSession() {
        // Progress exists: Cancel backs out of the current step — never wipe the floor plan.
        if !capturedRoomArray.isEmpty {
            // Already on the decision card — nothing to cancel.
            if postScanCardView != nil && !isSessionRunning {
                return
            }

            if isReadyToStart && !isSessionRunning {
                // Between rooms (after Scan next / Rescan) — back to post-scan.
                returnToPostScanKeepingRooms()
                return
            }

            // Mid active scan of an additional room — confirm, then keep prior rooms.
            let alert = UIAlertController(
                title: "Stop this room?",
                message: "Your other rooms will be kept.",
                preferredStyle: .alert
            )
            alert.addAction(
                UIAlertAction(title: "Keep scanning", style: .cancel, handler: nil)
            )
            alert.addAction(
                UIAlertAction(title: "Stop", style: .default) { [weak self] _ in
                    self?.returnToPostScanKeepingRooms()
                }
            )
            present(alert, animated: true, completion: nil)
            return
        }

        // No rooms yet — abandoning the whole session.
        let alertController = UIAlertController(
            title: "Cancel scan?",
            message: "Nothing will be saved.",
            preferredStyle: .alert
        )
        alertController.addAction(
            UIAlertAction(title: "Keep scanning", style: .cancel, handler: nil)
        )
        alertController.addAction(
            UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in
                self?.finalStructure = nil
                self?.sendScanResultAndDismiss(status: .Canceled)
            }
        )
        present(alertController, animated: true, completion: nil)
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

        // Capture errors: discard this room. Keep only rooms finished earlier.
        if let captureCopy {
            let priorCount = self.capturedRoomArray.count
            let primary: ScanErrorPrimaryAction
            let message: String
            switch captureCopy.code {
            case "deviceNotSupported":
                primary = .closeOnly
                message = captureCopy.message
            default:
                if priorCount > 0 {
                    primary = .recover
                    message = self.recoveryHelperMessage(priorRoomCount: priorCount)
                } else {
                    primary = .tryAgain
                    message = captureCopy.message
                }
            }
            self.showErrorCard(
                title: captureCopy.title,
                message: message,
                primaryAction: primary
            )
            self.exportPendingAfterBuild = false
            return
        }

        let roomBuilder = RoomBuilder(options: [.beautifyObjects])
        Task {
            do {
                let capturedRoom = try await roomBuilder.capturedRoom(from: didEndWith)
                let shouldDiscard = await MainActor.run { () -> Bool in
                    if self.discardNextAppendedRoom {
                        self.discardNextAppendedRoom = false
                        print("[RoomPlan] Discarding rebuilt room after Rescan")
                        return true
                    }
                    return false
                }
                if shouldDiscard {
                    return
                }
                print("[RoomPlan] Appending new captured room")
                await MainActor.run {
                    self.capturedRoomArray.append(capturedRoom)
                }
                await self.finalizePostScanAfterRoomAppended()
            } catch {
                // Non-fatal: user stays in the scan UI and can try again.
                print("[RoomPlan] Failed to build captured room: \(error)")
                let message = error.localizedDescription
                self.emitScanError(message: message, context: "roomBuilder", code: "roomBuilderFailed")
                let priorCount = self.capturedRoomArray.count
                await MainActor.run {
                    self.isPostScanAwaitingValidation = false
                    self.exportPendingAfterBuild = false
                }
                if priorCount > 0 {
                    self.showErrorCard(
                        title: "Couldn’t process this room",
                        message: self.recoveryHelperMessage(priorRoomCount: priorCount),
                        primaryAction: .recover
                    )
                } else {
                    self.showErrorCard(
                        title: "Couldn’t process this room",
                        message: "The scan finished, but the room model couldn’t be built. Try scanning again.",
                        primaryAction: .tryAgain
                    )
                }
                return
            }
        }
    }

    /// After a room is appended: dry-run StructureBuilder (room 2+), then unlock post-scan actions.
    private func finalizePostScanAfterRoomAppended() async {
        let roomsSnapshot = capturedRoomArray

        await MainActor.run {
            self.postScanExpectedRoomCount = roomsSnapshot.count
            self.isPostScanAwaitingValidation = true
            self.updatePostScanCopy()
            self.setPostScanActionsEnabled(false)
        }

        if roomsSnapshot.count >= 2 {
            do {
                _ = try await structureBuilder.capturedStructure(from: roomsSnapshot)
            } catch {
                await MainActor.run {
                    self.handleEarlyMergeFailure(error: error)
                }
                return
            }
        }

        await MainActor.run {
            self.isPostScanAwaitingValidation = false
            self.postScanExpectedRoomCount = self.capturedRoomArray.count
            self.updatePostScanCopy()
            self.setPostScanActionsEnabled(true)

            // If Done was tapped while the session was still running, export now that the
            // room is built (and merge-validated) rather than racing a fixed delay.
            if self.exportPendingAfterBuild {
                self.exportPendingAfterBuild = false
                self.exportResults()
            }
        }
    }

    /// Last room failed to merge — drop it and offer Rescan while keeping prior rooms.
    private func handleEarlyMergeFailure(error: Error) {
        if !capturedRoomArray.isEmpty {
            capturedRoomArray.removeLast()
        }
        postScanExpectedRoomCount = capturedRoomArray.count
        isPostScanAwaitingValidation = false
        exportPendingAfterBuild = false

        print("[RoomPlan] ERROR MERGING (early): \(error)")
        let message = error.localizedDescription
        emitScanError(message: message, context: "earlyMerge", code: "earlyMergeFailed")

        let priorCount = capturedRoomArray.count
        if priorCount > 0 {
            showErrorCard(
                title: "Couldn’t add this room",
                message:
                    "This room didn’t line up with your other scans. Rescan it, or finish with the rooms you already have.",
                primaryAction: .recover
            )
        } else {
            showErrorCard(
                title: "Couldn’t add this room",
                message:
                    "This room didn’t line up with your floor plan. Try scanning again.",
                primaryAction: .tryAgain
            )
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
