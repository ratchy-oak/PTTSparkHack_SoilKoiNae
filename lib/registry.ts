export type StaffProfile = { display_name: string; role: string; active: boolean };
export function canUseOffice(profile: StaffProfile | null): boolean {
 return Boolean(profile?.active && ['admin','manager','extension','inspector'].includes(profile.role));
}
