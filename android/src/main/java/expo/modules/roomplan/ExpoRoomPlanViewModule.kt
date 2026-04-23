package expo.modules.roomplan

import android.content.Context
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ExpoRoomPlanViewModule : Module() {
  override fun definition() = ModuleDefinition {
    // Name must match the iOS view module so JS can require the same manager
    Name("ExpoRoomPlanView")

    // Register a View factory. The View itself will throw on Android.
    View<RoomPlanView>({ context: Context -> RoomPlanView(context) }) {
      // Mirror props to satisfy the JS/TS surface. They are no-ops here.
      Prop<RoomPlanView, String?>("scanName") { _: RoomPlanView, _: String? -> }
      Prop<RoomPlanView, String?>("exportType") { _: RoomPlanView, _: String? -> }
      Prop<RoomPlanView, Boolean?>("sendFileLoc") { _: RoomPlanView, _: Boolean? -> }
      Prop<RoomPlanView, Boolean?>("running") { _: RoomPlanView, _: Boolean? -> }
      Prop<RoomPlanView, Double?>("exportTrigger") { _: RoomPlanView, _: Double? -> }

      Events("onStatus", "onExported")
    }
  }
}
