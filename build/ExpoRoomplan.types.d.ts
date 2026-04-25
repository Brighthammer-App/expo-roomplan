export declare enum ScanStatus {
    NotStarted = "NotStarted",
    Canceled = "Canceled",
    Error = "Error",
    OK = "OK"
}
export declare enum ExportType {
    Parametric = "PARAMETRIC",
    Mesh = "MESH",
    Model = "MODEL"
}
export interface UseRoomPlanParams {
    exportType?: ExportType;
    sendFileLoc?: boolean;
}
export interface ExpoRoomPlanModuleType {
    startCapture(scanName: string, exportType: ExportType, sendFileLoc: boolean): Promise<void>;
    stopCapture(): Promise<void>;
    addListener?(eventName: string, listener: (event: any) => void): {
        remove: () => void;
    };
    removeListeners?(count: number): void;
}
export interface UseRoomPlanInterface {
    startRoomPlan: (scanName: string) => Promise<void>;
    roomScanStatus: ScanStatus;
    jsonUrl: string | null;
    scanUrl: string | null;
}
//# sourceMappingURL=ExpoRoomplan.types.d.ts.map