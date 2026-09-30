def replace_in_file(filepath):
    with open(filepath, 'r') as f:
        text = f.read()
    
    text = text.replace("SEARCHING", "PUBLISHED")
    text = text.replace("AWAITING_DEPARTURE", "ASSIGNED")
    text = text.replace("AT_PICKUP", "ARRIVED")
    
    with open(filepath, 'w') as f:
        f.write(text)

replace_in_file('src/App.tsx')
replace_in_file('src/i18n.ts')
replace_in_file('src/de.json')
