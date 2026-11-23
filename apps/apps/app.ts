export const appId = 'dev.disposabl.fresh.traveldesk';
export const grants = 'device.contacts purpose.contacts\ndevice.calendar-write-only purpose.calendar\ndevice.calendar purpose.calendar';

export const answer = () => {
  throw new Error('Travel Desk uses the native Contacts and Calendar providers.');
};
