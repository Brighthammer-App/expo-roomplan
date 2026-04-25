import { useCallback, useMemo, useRef, useState } from "react";
/**
 * React hook that controls the {@link RoomPlanView} and exposes a friendly API.
 *
 * It returns `viewProps` to spread onto the component, `controls` with imperative methods (start, cancel,
 * finishScan, addRoom, exportScan, reset), and `state` reflecting the current scanning lifecycle.
 *
 * @example
 * ```tsx
 * const { viewProps, controls } = useRoomPlanView({ scanName: 'Demo' });
 * return (
 *   <>
 *     <RoomPlanView {...viewProps} style={StyleSheet.absoluteFill} />
 *     <Button onPress={controls.finishScan} title="Finish" />
 *   </>
 * );
 * ```
 */
export function useRoomPlanView(options = {}) {
    const { scanName, exportType, exportOnFinish = true, sendFileLoc = true, autoCloseOnTerminalStatus = false, onStatus, onPreview, onExported, } = options;
    // Internal control state
    const [running, setRunning] = useState(false);
    const [finishTrigger, setFinishTrigger] = useState();
    const [addAnotherTrigger, setAddAnotherTrigger] = useState();
    const [exportTrigger, setExportTrigger] = useState();
    // Derived UI state
    const [status, setStatus] = useState(undefined);
    const [isPreviewVisible, setPreviewVisible] = useState(false);
    const [lastExport, setLastExport] = useState(undefined);
    const [lastError, setLastError] = useState(undefined);
    // Cache callbacks refs to avoid stale closures in event handlers
    const optsRef = useRef({
        onStatus,
        onPreview,
        onExported,
        autoCloseOnTerminalStatus,
    });
    optsRef.current = {
        onStatus,
        onPreview,
        onExported,
        autoCloseOnTerminalStatus,
    };
    // Controller methods
    const start = useCallback(() => {
        setRunning(true);
        setPreviewVisible(false);
        setLastError(undefined);
    }, []);
    const cancel = useCallback(() => {
        setRunning(false);
    }, []);
    const finishScan = useCallback(() => {
        setFinishTrigger(Date.now());
    }, []);
    const addRoom = useCallback(() => {
        setAddAnotherTrigger(Date.now());
        setPreviewVisible(false);
    }, []);
    const exportScan = useCallback(() => {
        setExportTrigger(Date.now());
    }, []);
    const reset = useCallback(() => {
        setRunning(false);
        setFinishTrigger(undefined);
        setAddAnotherTrigger(undefined);
        setExportTrigger(undefined);
        setPreviewVisible(false);
        setStatus(undefined);
        setLastError(undefined);
        setLastExport(undefined);
    }, []);
    // Event handlers that keep internal state in sync but forward to user callbacks
    const handleStatus = useCallback((e) => {
        const s = e.nativeEvent.status;
        const errorMessage = e.nativeEvent.errorMessage;
        setStatus(s);
        if (errorMessage)
            setLastError(errorMessage);
        if (optsRef.current.onStatus)
            optsRef.current.onStatus(e);
        if (optsRef.current.autoCloseOnTerminalStatus) {
            if (s === "OK" || s === "Error" || s === "Canceled") {
                setRunning(false);
            }
        }
    }, []);
    const handlePreview = useCallback(() => {
        setPreviewVisible(true);
        if (optsRef.current.onPreview)
            optsRef.current.onPreview();
    }, []);
    const handleExported = useCallback((e) => {
        setLastExport({ ...e.nativeEvent });
        if (optsRef.current.onExported)
            optsRef.current.onExported(e);
    }, []);
    const viewProps = useMemo(() => ({
        // Identity props
        scanName,
        exportType,
        exportOnFinish,
        sendFileLoc,
        // Control props
        running,
        finishTrigger,
        addAnotherTrigger,
        exportTrigger,
        // Events
        onStatus: handleStatus,
        onPreview: handlePreview,
        onExported: handleExported,
    }), [
        scanName,
        exportType,
        exportOnFinish,
        sendFileLoc,
        running,
        finishTrigger,
        addAnotherTrigger,
        exportTrigger,
        handleStatus,
        handlePreview,
        handleExported,
    ]);
    return {
        viewProps,
        controls: { start, cancel, finishScan, addRoom, exportScan, reset },
        state: {
            isRunning: running,
            status,
            isPreviewVisible,
            lastExport,
            lastError,
        },
    };
}
//# sourceMappingURL=useRoomPlanView.js.map