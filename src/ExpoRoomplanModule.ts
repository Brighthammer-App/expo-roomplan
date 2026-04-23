import type { ExpoRoomPlanModuleType } from "./ExpoRoomplan.types";
import { requireNativeModule } from "expo-modules-core";
import { Platform } from "react-native";

const ExpoRoomplan: ExpoRoomPlanModuleType =
  Platform.OS === "ios"
    ? requireNativeModule<ExpoRoomPlanModuleType>("ExpoRoomPlan")
    : {
        startCapture: async () => { throw new Error("RoomPlan is not available on Android."); },
        stopCapture: async () => { throw new Error("RoomPlan is not available on Android."); },
      };

export default ExpoRoomplan;
