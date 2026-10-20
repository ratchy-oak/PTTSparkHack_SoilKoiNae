import type { Metadata } from 'next';
import localFont from 'next/font/local';
import './globals.css';
const kanit = localFont({
 src: [
  {path:'./fonts/kanit/Kanit-Regular.ttf',weight:'400',style:'normal'},
  {path:'./fonts/kanit/Kanit-Medium.ttf',weight:'500',style:'normal'},
  {path:'./fonts/kanit/Kanit-SemiBold.ttf',weight:'600',style:'normal'},
  {path:'./fonts/kanit/Kanit-Bold.ttf',weight:'700',style:'normal'},
 ],
 variable:'--font-kanit',display:'swap',
});
export const metadata: Metadata = { title: 'Soilข่อยแน · เข้าใจดิน ดูแลนา', description: 'แผนที่ติดตามสภาพดินและอุปกรณ์ตรวจวัด สำหรับชุมชนผักไหม ศรีสะเกษ' };
export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="th" className={kanit.variable}><body>{children}</body></html>;
}
