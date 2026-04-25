import React, { PropsWithChildren } from "react";
import type { RoomPlanViewProps } from "./ExpoRoomplanView.types";
import type { UseRoomPlanViewOptions, UseRoomPlanViewReturn } from "./useRoomPlanView";
/**
 * Provides RoomPlan controls, state, and view props to a React subtree.
 *
 * Wrap any part of your UI that needs to start/cancel/finish scanning or render the RoomPlanView through
 * {@link RoomPlanViewConsumer}. Under the hood this initialises {@link useRoomPlanView} with the given options.
 *
 * @param props.providerOptions Options passed to {@link useRoomPlanView} plus children.
 * @remarks This is the easiest way to enable cross-tree control without threading props.
 * @example
 * ```tsx
 * <RoomPlanProvider scanName="MyRoom">
 *   <Toolbar />
 *   <RoomPlanViewConsumer style={StyleSheet.absoluteFill} />
 * </RoomPlanProvider>
 * ```
 */
export declare function RoomPlanProvider(props: PropsWithChildren<UseRoomPlanViewOptions>): React.JSX.Element;
/**
 * Access the RoomPlan context created by {@link RoomPlanProvider}.
 *
 * @returns The same shape returned by {@link useRoomPlanView}: `{ viewProps, controls, state }`.
 * @throws If used outside of a {@link RoomPlanProvider}.
 */
export declare function useRoomPlanContext(): UseRoomPlanViewReturn;
/**
 * Convenience component that renders {@link RoomPlanView} using `viewProps` from {@link useRoomPlanContext}.
 *
 * Pass additional view props (e.g. `style`) to override or extend those from context.
 */
export declare function RoomPlanViewConsumer(props: Partial<RoomPlanViewProps>): React.JSX.Element;
//# sourceMappingURL=RoomPlanProvider.d.ts.map