import { requireNativeModule } from "expo-modules-core";
import { Platform } from "react-native";
const ExpoRoomplan = Platform.OS === "ios"
    ? requireNativeModule("ExpoRoomPlan")
    : {
        startCapture: async () => { throw new Error("RoomPlan is not available on Android."); },
        stopCapture: async () => { throw new Error("RoomPlan is not available on Android."); },
    };
export default ExpoRoomplan;
//# sourceMappingURL=ExpoRoomplanModule.js.map