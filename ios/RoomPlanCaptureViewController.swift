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

    override func viewDidLoad() {
        super.viewDidLoad()
        setupRoomCaptureView()
        setupActivityIndicator()
    }

    private func setupActivityIndicator() {
        activityIndicator.center = self.view.center
        activityIndicator.hidesWhenStopped = true
        activityIndicator.color = UIColor.white
        view.addSubview(activityIndicator)
    }

    // Backdrop is sized by Auto Layout to wrap its content; capture view fills above it.
    private var backdropView: UIVisualEffectView!

    private func setupRoomCaptureView() {
        // Temporary full-size frame — trimmed to sit above the backdrop in viewDidLayoutSubviews.
        roomCaptureView = RoomCaptureView(frame: view.bounds)
        roomCaptureView?.captureSession.delegate = self
        // Hide until scanning starts so the AV warm-up preview shows through underneath
        roomCaptureView?.alpha = 0
        view.insertSubview(roomCaptureView, at: 0)

        setupButtons()
        setupConstraints()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Keep the ring layer sized to the button bounds
        if let ring = finishButton.layer.sublayers?.first(where: { $0.name == "recordRing" }) as? CAShapeLayer {
            let inset: CGFloat = 3
            let rect = finishButton.bounds.insetBy(dx: inset, dy: inset)
            ring.path = UIBezierPath(ovalIn: rect).cgPath
            ring.frame = finishButton.bounds
        }

        // Squash capture view to end exactly where the frosted backdrop begins
        if let backdrop = backdropView {
            let backdropTop = backdrop.frame.minY
            roomCaptureView.frame = CGRect(
                x: 0, y: 0,
                width: view.bounds.width,
                height: backdropTop
            )
        }
    }

    private func setupButtons() {
        // Record/stop button — large circular red button at the bottom centre
        finishButton = UIButton()
        finishButton.translatesAutoresizingMaskIntoConstraints = false
        finishButton.backgroundColor = UIColor.systemRed
        finishButton.layer.masksToBounds = true
        finishButton.layer.cornerRadius = 36  // half of 72pt → circle

        // Record circle icon — shown before scanning starts
        let recordConfig = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        let recordImage = UIImage(systemName: "circle.fill", withConfiguration: recordConfig)
        finishButton.setImage(recordImage, for: .normal)
        finishButton.tintColor = .white

        // Outer ring (like a camera shutter ring)
        let ringLayer = CAShapeLayer()
        ringLayer.strokeColor = UIColor.white.cgColor
        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.lineWidth = 3
        ringLayer.name = "recordRing"
        finishButton.layer.addSublayer(ringLayer)

        finishButton.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)

        // Frosted backdrop — height driven by content via Auto Layout
        backdropView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.isUserInteractionEnabled = false
        view.addSubview(backdropView)

        view.addSubview(finishButton)

        // Cancel button — top left, text only
        cancelButton = UIButton()
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        cancelButton.layer.masksToBounds = true
        cancelButton.layer.cornerRadius = 15
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        cancelButton.configuration = config

        cancelButton.addTarget(self, action: #selector(cancelSession), for: .touchUpInside)
        view.addSubview(cancelButton)
    }

    private func setupConstraints() {
        backdropTopToFinishConstraint = backdropView.topAnchor.constraint(
            equalTo: finishButton.topAnchor, constant: -20
        )

        NSLayoutConstraint.activate([
            // Frosted backdrop — spans full width, anchored to bottom, top driven by button
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdropTopToFinishConstraint,

            // Record button — centred, 20pt above safe area bottom
            finishButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20
            ),
            finishButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            finishButton.widthAnchor.constraint(equalToConstant: 72),
            finishButton.heightAnchor.constraint(equalToConstant: 72),

            // Cancel button — top left
            cancelButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10
            ),
            cancelButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20
            ),
            cancelButton.heightAnchor.constraint(equalToConstant: 30),
        ])
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
        backdropView.isUserInteractionEnabled = true

        UIView.transition(
            with: cancelButton,
            duration: 0.5,
            options: .transitionCrossDissolve,
            animations: {
                self.cancelButton.backgroundColor = UIColor.black
                    .withAlphaComponent(0.6)
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

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            card.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16
            ),

            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
    }

    private func teardownPostScanUI() {
        postScanCardView?.removeFromSuperview()
        postScanCardView = nil
        backdropTopToPostScanConstraint?.isActive = false
        backdropTopToPostScanConstraint = nil
        backdropTopToFinishConstraint.isActive = true
        backdropView.isUserInteractionEnabled = false
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
        previewLayer.frame = view.bounds
        // Insert behind everything — RoomCaptureView is at index 0, so go below it
        view.layer.insertSublayer(previewLayer, at: 0)

        avSession = session
        avPreviewLayer = previewLayer

        // Start on a background thread so we don't block the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func stopAVPreview() {
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
                self.cancelButton.backgroundColor = UIColor.white
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
        label.text = "Tap the button below to start scanning"
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        label.numberOfLines = 0
        overlay.addSubview(label)

        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -140),
            label.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -32),
        ])
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

        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: finishButton.topAnchor, constant: -20),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
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
                self.cancelButton.backgroundColor = UIColor.black.withAlphaComponent(0.4)
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
        UIView.animate(withDuration: 0.2) {
            self.finishButton.backgroundColor = UIColor.systemRed
        }
        let stopConfig = UIImage.SymbolConfiguration(pointSize: 26, weight: .bold)
        let stopImage = UIImage(systemName: "stop.fill", withConfiguration: stopConfig)
        finishButton.setImage(stopImage, for: .normal)
        finishButton.tintColor = .white
        finishButton.isEnabled = true
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
