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
    // Shown behind the instructions overlay; crossfades out when scanning starts.
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
    private var backdropTopToFinishConstraint: NSLayoutConstraint!
    private var backdropTopToPostScanConstraint: NSLayoutConstraint?

    /// Matches quick-camera `TABLET_RAIL_WIDTH` / `TABLET_MIN_DIMENSION` / `CameraShutterButton`.
    private let railWidth: CGFloat = 120
    private let tabletMinDimension: CGFloat = 768
    private let phoneFinishButtonSize: CGFloat = 72
    private let tabletFinishButtonSize: CGFloat = 84
    private let shutterBorderWidth: CGFloat = 4
    private let shutterRed = UIColor(red: 1, green: 59.0 / 255.0, blue: 48.0 / 255.0, alpha: 1)

    private var sideRailView: UIView!
    private var sideRailWidthConstraint: NSLayoutConstraint!
    private var phoneFinishConstraints: [NSLayoutConstraint] = []
    private var phoneFinishBottomConstraint: NSLayoutConstraint!
    private var tabletFinishConstraints: [NSLayoutConstraint] = []
    private var tabletFinishCenterYConstraint: NSLayoutConstraint!
    private var finishButtonWidthConstraint: NSLayoutConstraint!
    private var finishButtonHeightConstraint: NSLayoutConstraint!
    private var finishButtonInnerView: UIView!
    private var finishButtonInnerWidthConstraint: NSLayoutConstraint!
    private var finishButtonInnerHeightConstraint: NSLayoutConstraint!
    private var finishButtonShowsRecordingStyle: Bool = false
    private var backdropTrailingPhoneConstraint: NSLayoutConstraint!
    private var backdropTrailingTabletConstraint: NSLayoutConstraint!
    private var postScanCardTrailingConstraint: NSLayoutConstraint?
    private var readyLabelBottomConstraint: NSLayoutConstraint?
    private var readyLabelCenterYConstraint: NSLayoutConstraint?
    private var readyInstructionLabel: UILabel?

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

    // Backdrop is sized by Auto Layout to wrap its content (phone bottom chrome / post-scan).
    private var backdropView: UIVisualEffectView!

    private var isTabletLayout: Bool {
        min(view.bounds.width, view.bounds.height) >= tabletMinDimension
    }

    /// Phone: full screen. iPad: main column left of the 120pt trailing rail (inside safe area).
    private var availablePreviewRect: CGRect {
        let bounds = view.bounds
        guard isTabletLayout else { return bounds }

        let insets = view.safeAreaInsets
        let width = max(0, bounds.width - insets.left - insets.right - railWidth)
        return CGRect(x: insets.left, y: 0, width: width, height: bounds.height)
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

        // Frosted backdrop — height driven by content via Auto Layout (phone / post-scan)
        backdropView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
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
    }

    /// Frosted pill chrome inspired by quick-camera Done (`rgba(255,255,255,0.12)` + hairline).
    private func applyCancelButtonChrome(emphasized: Bool) {
        var config = UIButton.Configuration.plain()
        config.title = "Cancel"
        config.baseForegroundColor = UIColor.white.withAlphaComponent(0.96)
        config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
            outgoing.kern = 0.35
            return outgoing
        }
        config.background.backgroundColor = UIColor.white.withAlphaComponent(emphasized ? 0.18 : 0.12)
        config.background.cornerRadius = 22
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        config.background.strokeWidth = 1.0 / scale
        config.background.strokeColor = UIColor.white.withAlphaComponent(0.32)
        cancelButton.configuration = config
        cancelButton.alpha = cancelButton.isEnabled ? 1.0 : 0.4
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

        // Phone: match quick camera `paddingBottom: Math.max(insets.bottom, 12) + 8`
        phoneFinishBottomConstraint = finishButton.bottomAnchor.constraint(
            equalTo: view.bottomAnchor, constant: -20
        )
        phoneFinishConstraints = [
            phoneFinishBottomConstraint,
            finishButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ]

        // iPad: match quick-camera rail (`paddingTop: 24` + vertically centered stack).
        // Asymmetric top padding shifts the visual center ~12pt below mid-rail.
        tabletFinishCenterYConstraint = finishButton.centerYAnchor.constraint(
            equalTo: sideRailView.centerYAnchor, constant: 12
        )
        tabletFinishConstraints = [
            finishButton.centerXAnchor.constraint(equalTo: sideRailView.centerXAnchor),
            tabletFinishCenterYConstraint,
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

            // Cancel button — top left of main column
            cancelButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12
            ),
            cancelButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16
            ),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    /// Swap phone bottom chrome vs iPad right rail; hide frosted bar on iPad while scanning.
    private func applyControlLayout() {
        let tablet = isTabletLayout
        let isPostScan = postScanCardView != nil

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

        if tablet {
            NSLayoutConstraint.activate(tabletFinishConstraints)
            finishButtonWidthConstraint.constant = tabletFinishButtonSize
            finishButtonHeightConstraint.constant = tabletFinishButtonSize

            backdropTrailingPhoneConstraint.isActive = false
            backdropTrailingTabletConstraint.isActive = true
            // No bottom frosted chrome during scan on iPad
            backdropView.isHidden = !isPostScan
            if !isPostScan {
                backdropTopToFinishConstraint.isActive = false
            }
        } else {
            NSLayoutConstraint.activate(phoneFinishConstraints)
            finishButtonWidthConstraint.constant = phoneFinishButtonSize
            finishButtonHeightConstraint.constant = phoneFinishButtonSize
            // Same bottom inset as quick-camera shutter row
            phoneFinishBottomConstraint.constant =
                -(max(view.safeAreaInsets.bottom, 12) + 8)

            backdropTrailingTabletConstraint.isActive = false
            backdropTrailingPhoneConstraint.isActive = true
            backdropView.isHidden = false
            if !isPostScan {
                backdropTopToFinishConstraint.isActive = true
            }
        }

        applyFinishButtonAppearance(animated: false)

        updateReadyOverlayForLayout(isTablet: tablet)

        if tablet {
            view.bringSubviewToFront(sideRailView)
        }
        view.bringSubviewToFront(finishButton)
        view.bringSubviewToFront(cancelButton)
        if let card = postScanCardView {
            view.bringSubviewToFront(card)
            view.bringSubviewToFront(cancelButton)
        }
    }

    private func updateReadyOverlayForLayout(isTablet: Bool) {
        guard let label = readyInstructionLabel else { return }
        label.text = isTablet
            ? "Tap the button on the right to start scanning"
            : "Tap the button below to start scanning"
        readyLabelBottomConstraint?.isActive = !isTablet
        readyLabelCenterYConstraint?.isActive = isTablet
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
        backdropView.isUserInteractionEnabled = true

        UIView.transition(
            with: cancelButton,
            duration: 0.5,
            options: .transitionCrossDissolve,
            animations: {
                self.applyCancelButtonChrome(emphasized: true)
            },
            completion: nil
        )

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
        setupReadyUI()
        startAVPreview()
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
                self.sendScanResultAndDismiss(status: .Error, errorMessage: error.localizedDescription, errorContext: "exportResults")
                return
            }
        }
    }

    func sendScanResultAndDismiss(status: ScanStatus? = nil, scanUrl: String? = nil, jsonUrl: String? = nil, errorMessage: String? = nil, errorContext: String? = nil) {
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

    // Shows instructions overlay with a large red record button before scanning begins
    private func setupReadyUI() {
        let overlay = UIView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        overlay.tag = 888
        overlay.isUserInteractionEnabled = false
        // Insert below finishButton so the button stays tappable
        view.insertSubview(overlay, belowSubview: finishButton)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        overlay.addSubview(label)
        readyInstructionLabel = label

        let bottomConstraint = label.bottomAnchor.constraint(
            equalTo: overlay.bottomAnchor, constant: -140
        )
        let centerYConstraint = label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        readyLabelBottomConstraint = bottomConstraint
        readyLabelCenterYConstraint = centerYConstraint

        let tablet = isTabletLayout
        label.text = tablet
            ? "Tap the button on the right to start scanning"
            : "Tap the button below to start scanning"

        var constraints: [NSLayoutConstraint] = [
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -32),
            tablet ? centerYConstraint : bottomConstraint,
        ]
        if tablet {
            // Keep the right rail undimmed and tappable
            constraints.append(
                overlay.trailingAnchor.constraint(equalTo: sideRailView.leadingAnchor)
            )
        } else {
            constraints.append(
                overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)
            )
        }
        NSLayoutConstraint.activate(constraints)
    }

    public func startSession() {
        print("[RoomPlan] starting session")
        // Dismiss the ready overlay if present
        if let overlay = view.viewWithTag(888) {
            UIView.animate(withDuration: 0.25, animations: {
                overlay.alpha = 0
            }, completion: { _ in
                overlay.removeFromSuperview()
            })
        }
        readyInstructionLabel = nil
        readyLabelBottomConstraint = nil
        readyLabelCenterYConstraint = nil
        isSessionRunning = true
        setFinishButtonToRecording()
        showScanningHint()

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
        hint.text = "Scan this room. For best results, scan one room at a time — stop and start again for each room."
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
        teardownPostScanUI()
        roomCaptureView?.captureSession.run(configuration: roomCaptureSessionConfig)
        isSessionRunning = true
        // Restore the record button
        setFinishButtonToRecording()
        finishButton.isHidden = false
        showScanningHint()
        UIView.transition(
            with: cancelButton,
            duration: 0.5,
            options: .transitionCrossDissolve,
            animations: {
                self.cancelButton.isEnabled = true
                self.applyCancelButtonChrome(emphasized: false)
            },
            completion: nil
        )
    }

    @objc
    public func stopSession() {
        roomCaptureView?.captureSession.stop(pauseARSession: false)
        isSessionRunning = false
        // Remove scanning hint
        view.viewWithTag(887)?.removeFromSuperview()
        // Hide the record button — post-scan UI has its own actions
        finishButton.isHidden = true
        setupPostScanUI()
    }

    @objc
    private func finishTapped() {
        if view.viewWithTag(888) != nil {
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
        let roomBuilder = RoomBuilder(options: [.beautifyObjects])
        Task {
            do {
                let capturedRoom = try await roomBuilder.capturedRoom(from: didEndWith)
                print("[RoomPlan] Appending new captured room")
                self.capturedRoomArray.append(capturedRoom)
            } catch {
                // Non-fatal: user stays in the scan UI and can try again.
                // Forward the error to React for Sentry logging without dismissing.
                print("[RoomPlan] Failed to build captured room: \(error)")
                self.onScanError?(["errorMessage": error.localizedDescription, "errorContext": "roomBuilder"])
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
