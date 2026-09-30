with open('src/App.tsx', 'r') as f:
    text = f.read()

text = text.replace("import {useCallback,useEffect,useRef,useState} from 'react';", "import {useCallback,useEffect,useRef,useState} from 'react';\nimport { useLocation, useNavigate as useReactNavigate } from 'react-router-dom';")

with open('src/App.tsx', 'w') as f:
    f.write(text)
