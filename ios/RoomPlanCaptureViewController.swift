//  RoomPlanCaptureViewController.swift

import Foundation
import RealityKit
import RoomPlan
import UIKit

@available(iOS 17.0, *)
class RoomPlanCaptureViewController: UIViewController, RoomCaptureViewDelegate,
    RoomCaptureSessionDelegate
{
    private var roomCaptureView: RoomCaptureView!
    private var roomCaptureSessionConfig: RoomCaptureSession.Configuration =
        RoomCaptureSession.Configuration()
    private var isSessionRunning: Bool = false

    private var finalResults: CapturedRoom?
    private var finalStructure: CapturedStructure?
    private let structureBuilder = StructureBuilder(options: [.beautifyObjects])

    var onDismiss: (([String: Any]) -> Void)?

    var scanName: String?
    var exportType: String?
    var sendFileLoc: Bool?
    var capturedRoomArray: [CapturedRoom] = []

    // UI elements
    private let activityIndicator = UIActivityIndicatorView(style: .large)
    @IBOutlet var cancelButton: UIButton!
    @IBOutlet var finishButton: UIButton!
    @IBOutlet var anotherScanButton: UIButton!
    @IBOutlet var exportButton: UIButton!

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

    private func setupRoomCaptureView() {
        // Shift the capture view up by 70pt so the 3D model sits mid-screen
        // rather than being pushed down by the button strip at the bottom.
        let offset: CGFloat = -70
        roomCaptureView = RoomCaptureView(frame: CGRect(
            x: view.bounds.origin.x,
            y: view.bounds.origin.y + offset,
            width: view.bounds.width,
            height: view.bounds.height
        ))
        roomCaptureView?.captureSession.delegate = self
        view.insertSubview(roomCaptureView, at: 0)

        setupButtons()
        setupConstraints()
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

        // Frosted backdrop so the button reads clearly over the AR view
        let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.tag = 886
        backdrop.isUserInteractionEnabled = false
        view.addSubview(backdrop)

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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the ring layer sized to the button bounds
        if let ring = finishButton.layer.sublayers?.first(where: { $0.name == "recordRing" }) as? CAShapeLayer {
            let inset: CGFloat = 3
            let rect = finishButton.bounds.insetBy(dx: inset, dy: inset)
            ring.path = UIBezierPath(ovalIn: rect).cgPath
            ring.frame = finishButton.bounds
        }
    }

    private func setupConstraints() {
        let backdrop = view.viewWithTag(886)!
        NSLayoutConstraint.activate([
            // Frosted backdrop strip at the bottom
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.heightAnchor.constraint(equalToConstant: 140),

            // Record button — bottom centre, above safe area
            finishButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -24
            ),
            finishButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            finishButton.widthAnchor.constraint(equalToConstant: 72),
            finishButton.heightAnchor.constraint(equalToConstant: 72),

            // Cancel button — top left
            cancelButton.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor,
                constant: 10
            ),
            cancelButton.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 20
            ),
            cancelButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func setupPostScanUI() {
        // initialize and set up the export button
        exportButton = UIButton()
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.setTitleColor(.white, for: .normal)
        exportButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        exportButton.titleLabel?.textAlignment = .center
        exportButton.titleLabel?.numberOfLines = 0
        exportButton.titleLabel?.font = UIFont.systemFont(
            ofSize: 16,
            weight: .bold
        )
        exportButton.setTitle("Done", for: .normal)
        // round corners
        exportButton.layer.masksToBounds = true
        exportButton.layer.cornerRadius = 15

        exportButton.addTarget(
            self,
            action: #selector(superExportResults),
            for: .touchUpInside
        )

        // initialize and set up the "anotherScan" button
        anotherScanButton = UIButton()
        anotherScanButton.translatesAutoresizingMaskIntoConstraints = false
        anotherScanButton.setTitleColor(.white, for: .normal)
        anotherScanButton.backgroundColor = UIColor.black.withAlphaComponent(
            0.6
        )
        anotherScanButton.titleLabel?.textAlignment = .center
        anotherScanButton.titleLabel?.numberOfLines = 0
        anotherScanButton.titleLabel?.font = UIFont.systemFont(
            ofSize: 16,
            weight: .bold
        )
        anotherScanButton.setTitle("Add Another Room to Scan", for: .normal)  // text
        // round corners
        anotherScanButton.layer.masksToBounds = true
        anotherScanButton.layer.cornerRadius = 15

        anotherScanButton.addTarget(
            self,
            action: #selector(restartSession),
            for: .touchUpInside
        )

        let buttonStack = UIStackView(arrangedSubviews: [
            exportButton, anotherScanButton,
        ])
        buttonStack.axis = .vertical
        buttonStack.spacing = 16
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(buttonStack)

        // alter text on cancel buttons
        UIView.transition(
            with: cancelButton,
            duration: 0.5,
            options: .transitionCrossDissolve,
            animations: {
                self.cancelButton.backgroundColor = UIColor.black
                    .withAlphaComponent(0.6)  // make button background visible
            },
            completion: nil
        )
        // Keep Finish active; it will now confirm exit when no session is running.

        NSLayoutConstraint.activate([
            exportButton.heightAnchor.constraint(equalToConstant: 50),
            anotherScanButton.heightAnchor.constraint(equalToConstant: 50),

            buttonStack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: 20
            ),
            buttonStack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -20
            ),
            buttonStack.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -40
            ),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setupReadyUI()
    }

    override func viewWillDisappear(_ flag: Bool) {
        super.viewWillDisappear(flag)
        stopSession()
    }

    @IBAction func superExportResults(_ sender: Any) {
        // disable buttons after pressing upload
        exportButton.isEnabled = false
        exportButton.removeTarget(
            self,
            action: #selector(superExportResults),
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

        roomCaptureView?.captureSession.stop()

        // create a white overlay view that covers the entire screen
        let overlayView = UIView(frame: self.view.bounds)
        overlayView.backgroundColor = UIColor.white
        overlayView.alpha = 1
        overlayView.tag = 999

        // add the overlay above the roomCaptureView but below other UI elements
        self.view.insertSubview(overlayView, aboveSubview: roomCaptureView!)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.exportResults()
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
                print("[RoomPlan] ERROR MERGING")
                print("[RoomPlan] Error = \(error)")
                self.sendScanResultAndDismiss(status: .Error)
                return
            }
        }
    }

    func sendScanResultAndDismiss(status: ScanStatus? = nil, scanUrl: String? = nil, jsonUrl: String? = nil) {
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
        roomCaptureView?.captureSession.run(configuration: roomCaptureSessionConfig)
        isSessionRunning = true
        setFinishButtonToRecording()
        showScanningHint()
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
        exportButton.removeFromSuperview()
        anotherScanButton.removeFromSuperview()
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
            if let capturedRoom = try? await roomBuilder.capturedRoom(
                from: didEndWith
            ) {
                print("[RoomPlan] Appending new captured room")
                self.capturedRoomArray.append(capturedRoom)
            } else {
                print("[RoomPlan] Failed to build captured room.")
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
