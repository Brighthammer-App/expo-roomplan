import { useEffect, useState } from "react";
import { Platform } from "react-native";
import ExpoRoomPlan from "./ExpoRoomplanModule";
import { ScanStatus, ExportType, } from "./ExpoRoomplan.types";
export default function useRoomPlan(params) {
    const [roomScanStatus, setRoomScanStatus] = useState(ScanStatus.NotStarted);
    const [scanUrl, setScanUrl] = useState(null);
    const [jsonUrl, setJsonUrl] = useState(null);
    const [nativeError, setNativeError] = useState(null);
    useEffect(() => {
        const dismissSub = ExpoRoomPlan.addListener?.("onDismissEvent", (event) => {
            setRoomScanStatus(event.status);
            if (event.scanUrl)
                setScanUrl(event.scanUrl);
            if (event.jsonUrl)
                setJsonUrl(event.jsonUrl);
            if (event.errorMessage) {
                setNativeError({
                    message: event.errorMessage,
                    context: event.errorContext ?? "unknown",
                    code: event.errorCode,
                });
            }
            else if (event.status !== ScanStatus.Error) {
                setNativeError(null);
            }
        });
        // Mid-session errors (capture / room builder) — user may stay in scan UI
        const errorSub = ExpoRoomPlan.addListener?.("onScanError", (event) => {
            setNativeError({
                message: event.errorMessage,
                context: event.errorContext ?? "unknown",
                code: event.errorCode,
            });
        });
        return () => {
            dismissSub?.remove();
            errorSub?.remove();
        };
    }, []);
    const startRoomPlan = async (scanName) => {
        if (Platform.OS === "android") {
            throw new Error("RoomPlan SDK only available on iOS.");
        }
        // ExportType: defaults internally to 'parametric'
        // Model file location is not returned by default.
        const exportType = params?.exportType ?? ExportType.Parametric;
        const sendFileLoc = params?.sendFileLoc ?? false;
        ExpoRoomPlan.startCapture(scanName, exportType, sendFileLoc);
    };
    return {
        startRoomPlan,
        roomScanStatus,
        scanUrl,
        jsonUrl,
        nativeError,
    };
}
//# sourceMappingURL=useRoomPlan.js.map
