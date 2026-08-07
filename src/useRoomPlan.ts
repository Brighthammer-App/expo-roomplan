import { useEffect, useState } from "react";
import { Platform } from "react-native";
import ExpoRoomPlan from "./ExpoRoomplanModule";
import {
  UseRoomPlanParams,
  ScanStatus,
  UseRoomPlanInterface,
  ExportType,
} from "./ExpoRoomplan.types";

type NativeErrorState = { message: string; context: string; code?: string };

export default function useRoomPlan(
  params?: UseRoomPlanParams
): UseRoomPlanInterface {
  const [roomScanStatus, setRoomScanStatus] = useState<ScanStatus>(
    ScanStatus.NotStarted
  );
  const [scanUrl, setScanUrl] = useState<null | string>(null);
  const [jsonUrl, setJsonUrl] = useState<null | string>(null);
  const [nativeError, setNativeError] = useState<NativeErrorState | null>(null);

  useEffect(() => {
    const dismissSub = ExpoRoomPlan.addListener?.(
      "onDismissEvent",
      (event: {
        status: ScanStatus;
        scanUrl?: string;
        jsonUrl?: string;
        errorMessage?: string;
        errorContext?: string;
        errorCode?: string;
      }) => {
        setRoomScanStatus(event.status);
        if (event.scanUrl) setScanUrl(event.scanUrl);
        if (event.jsonUrl) setJsonUrl(event.jsonUrl);
        if (event.errorMessage) {
          setNativeError({
            message: event.errorMessage,
            context: event.errorContext ?? "unknown",
            code: event.errorCode,
          });
        } else if (event.status !== ScanStatus.Error) {
          setNativeError(null);
        }
      }
    );

    // Mid-session errors (capture / room builder) — user may stay in scan UI
    const errorSub = ExpoRoomPlan.addListener?.(
      "onScanError",
      (event: {
        errorMessage: string;
        errorContext?: string;
        errorCode?: string;
      }) => {
        setNativeError({
          message: event.errorMessage,
          context: event.errorContext ?? "unknown",
          code: event.errorCode,
        });
      }
    );

    return () => {
      dismissSub?.remove();
      errorSub?.remove();
    };
  }, []);

  const startRoomPlan = async (scanName: string) => {
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
