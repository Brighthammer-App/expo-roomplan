import type { RoomPlanViewProps } from "./ExpoRoomplanView.types";
import type { ExportType, ScanStatus } from "./ExpoRoomplan.types";
/**
 * Options for {@link useRoomPlanView}.
 */
export type UseRoomPlanViewOptions = {
    /** Base filename (no extension) for the exported files. */
    scanName?: string;
    /** Export mode for the USDZ model. */
    exportType?: ExportType;
    /** If true, finishing a capture also triggers export automatically. Defaults to `true`. */
    exportOnFinish?: boolean;
    /** When true, onExported receives file URLs instead of showing a share sheet. Defaults to `true`. */
    sendFileLoc?: boolean;
    /** Automatically stop scanning when status becomes OK, Error, or Canceled. Defaults to `false`. */
    autoCloseOnTerminalStatus?: boolean;
    /** Tap into status updates from the native view. */
    onStatus?: NonNullable<RoomPlanViewProps["onStatus"]>;
    /** Called when the native preview UI is presented after finishing a scan. */
    onPreview?: RoomPlanViewProps["onPreview"];
    /** Called after export completes with file URLs when `sendFileLoc` is true. */
    onExported?: NonNullable<RoomPlanViewProps["onExported"]>;
};
/**
 * Return type of {@link useRoomPlanView}.
 */
export type UseRoomPlanViewReturn = {
    viewProps: RoomPlanViewProps;
    controls: {
        /** Start a new scanning session. */
        start: () => void;
        /** Stop the current scanning session without exporting. */
        cancel: () => void;
        /** Stop capture and present the iOS preview UI (then export if `exportOnFinish` is true). */
        finishScan: () => void;
        /** Finish the current room and immediately start capturing another. */
        addRoom: () => void;
        /** Trigger export manually. Queued until a room is available if called too early. */
        exportScan: () => void;
        /** Reset all local hook state and triggers to an initial idle state. */
        reset: () => void;
    };
    state: {
        /** Whether the native view is currently scanning. */
        isRunning: boolean;
        /** Latest status reported by the native view. */
        status?: ScanStatus;
        /** True once the iOS preview UI has been presented for the current finish flow. */
        isPreviewVisible: boolean;
        /** Details of the last successful export, if any. */
        lastExport?: {
            scanUrl?: string;
            jsonUrl?: string;
        };
        /** Last error message received from the native view, if any. */
        lastError?: string;
    };
};
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
export declare function useRoomPlanView(options?: UseRoomPlanViewOptions): UseRoomPlanViewReturn;
//# sourceMappingURL=useRoomPlanView.d.ts.map