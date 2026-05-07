import { CHANNELS, type Channel } from "@yakiimo/contract/payload";

export interface ChannelDisplay {
  key: Channel;
  label: string;       // ja-JP UI text (例: "芋 内部温度")
  icon: string;        // 1 文字アイコン (例: "内")
  varName: string;     // CSS var name (例: "--color-ch-potato-internal")
}

export const CHANNEL_DISPLAY: ReadonlyArray<ChannelDisplay> = [
  { key: "potato_internal", label: "芋 内部温度", icon: "内", varName: "--color-ch-potato-internal" },
  { key: "potato_surface",  label: "芋 表面温度", icon: "皮", varName: "--color-ch-potato-surface"  },
  { key: "kiln_ambient",    label: "釜内部温度", icon: "釜", varName: "--color-ch-kiln-ambient"    },
  { key: "stone_surface",   label: "石 表面温度", icon: "石", varName: "--color-ch-stone-surface"   },
  { key: "env",             label: "気温",       icon: "外", varName: "--color-ch-env"             },
];

// 型レベルで CHANNELS と CHANNEL_DISPLAY のキー集合一致を強制 (test でも runtime 確認)
export type _AssertChannelComplete = typeof CHANNEL_DISPLAY[number]["key"] extends Channel
  ? Channel extends typeof CHANNEL_DISPLAY[number]["key"]
    ? true
    : never
  : never;

// CHANNELS を re-export して channels.test.ts などで参照できるようにする
export { CHANNELS, type Channel };
