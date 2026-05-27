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
            if (event.scanUrl) setScanUrl(event.scanUrl);
            if (event.jsonUrl) setJsonUrl(event.jsonUrl);
            if (event.errorMessage) {
                setNativeError({ message: event.errorMessage, context: event.errorContext ?? "unknown" });
            } else {
                setNativeError(null);
            }
        });
        const errorSub = ExpoRoomPlan.addListener?.("onScanError", (event) => {
            setNativeError({ message: event.errorMessage, context: event.errorContext ?? "unknown" });
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
        try {
            const exportType = params?.exportType ?? ExportType.Parametric;
            const sendFileLoc = params?.sendFileLoc ?? false;
            ExpoRoomPlan.startCapture(scanName, exportType, sendFileLoc);
        }
        catch (err) {
            throw err;
        }
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
