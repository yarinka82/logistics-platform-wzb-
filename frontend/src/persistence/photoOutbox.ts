/**
 * Photo Outbox (IndexedDB Persistence)
 * 
 * This module is designed to solve connectivity issues for drivers in remote areas or warehouses.
 * When a document or cargo is photographed, the image is immediately saved to the local browser database (IndexedDB) by this outbox.
 * If the network connection is lost, the photo is kept safely on the device and is not lost if the page is reloaded.
 * Once the internet connection is restored, the buffered photos are retrieved and uploaded to the backend.
 * After a successful upload, the local copy is deleted by the system.
 */

export interface PendingPhoto {
  key: string;
  data: string;
  savedAt: number;
}

function database(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("wzb-photo-outbox", 1);

    request.onupgradeneeded = () => {
      request.result.createObjectStore("photos", { keyPath: "key" });
    };

    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

export async function pendingPhoto(
  key: string,
): Promise<PendingPhoto | undefined> {
  const db = await database();
  return new Promise((resolve, reject) => {
    const tx = db.transaction("photos", "readonly");
    const r = tx.objectStore("photos").get(key);

    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
    tx.oncomplete = () => db.close();
  });
}

export async function savePhoto(key: string, data: string): Promise<void> {
  const db = await database();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction("photos", "readwrite");
    tx.objectStore("photos").put({ key, data, savedAt: Date.now() });

    tx.oncomplete = () => {
      db.close();
      resolve();
    };
    tx.onerror = () => reject(tx.error);
  });
}

export async function removePhoto(key: string): Promise<void> {
  const db = await database();
  await new Promise<void>((resolve, reject) => {
    const tx = db.transaction("photos", "readwrite");
    tx.objectStore("photos").delete(key);

    tx.oncomplete = () => {
      db.close();
      resolve();
    };
    tx.onerror = () => reject(tx.error);
  });
}
